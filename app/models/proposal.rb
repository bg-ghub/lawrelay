class Proposal < ApplicationRecord
  class InvalidTransition < StandardError; end

  STATUSES = %w[pending accepted declined withdrawn].freeze
  RATE_KINDS = %w[fixed hourly].freeze
  MAX_RATE_CENTS = (2**63) - 1 # SQLite stores integer amounts in a signed 64-bit column.

  belongs_to :assignment
  belongs_to :user, optional: true
  belongs_to :firm, optional: true
  has_many :audit_events, as: :auditable, dependent: :destroy
  after_create :notify_assignment_owner

  validates :message, presence: true, length: { maximum: 2_000 }
  validates :name, :email, presence: true, unless: :user
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :rate_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_RATE_CENTS }
  validates :rate_kind, inclusion: { in: RATE_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :assignment_id }, allow_nil: true
  validate :author_account_still_active, on: :create

  def display_name
    user&.full_name.presence || name
  end

  def contact_email
    return if user&.erased_at

    user&.email_address.presence || email
  end

  def rate_kind_label
    I18n.t("marketplace.rate_kinds.#{rate_kind}")
  end

  def owned_by?(candidate)
    candidate.present? && user_id == candidate.id
  end

  def withdraw!(actor:)
    transition_from_pending!("withdrawn", actor: actor, timestamp: :withdrawn_at)
  end

  def decline!(actor:)
    transition_from_pending!("declined", actor: actor, timestamp: :declined_at)
  end

  def accept!(actor:)
    transition_from_pending!("accepted", actor: actor, timestamp: :accepted_at)
  end

  private

  def author_account_still_active
    return unless user_id
    return if User.where(id: user_id, erased_at: nil, suspended_at: nil).exists?

    errors.add(:base, I18n.t("workflow.errors.assignment_not_available"))
  end

  def transition_from_pending!(next_status, actor:, timestamp:)
    # Use the same lock order as selection and assignment cancellation.
    assignment.with_lock do
      with_lock do
        raise InvalidTransition, "only pending proposals can transition" unless status == "pending"

        update!(status: next_status, timestamp => Time.current)
        audit_events.create!(actor_user: actor, firm: actor.primary_firm, action: "proposal.#{next_status}")
        notify_transition(next_status, actor:)
        self
      end
    end
  end

  def notify_assignment_owner
    Notification.publish!(user: assignment.creator_user, kind: "new_proposal", subject: self,
      assignment:, actor: user)
  end

  def notify_transition(next_status, actor:)
    if next_status == "withdrawn"
      return unless assignment.status == "open" && assignment.starts_at > Time.current

      recipient = assignment.creator_user
    else
      recipient = user
    end

    Notification.publish!(user: recipient, kind: "proposal_#{next_status}", subject: self, assignment:, actor:)
  end
end
