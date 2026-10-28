class Proposal < ApplicationRecord
  class InvalidTransition < StandardError; end

  STATUSES = %w[pending accepted declined withdrawn].freeze
  RATE_KINDS = %w[fixed hourly].freeze

  belongs_to :assignment
  belongs_to :user, optional: true
  belongs_to :firm, optional: true
  has_many :audit_events, as: :auditable, dependent: :destroy

  validates :message, presence: true, length: { maximum: 2_000 }
  validates :name, :email, presence: true, unless: :user
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :rate_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :rate_kind, inclusion: { in: RATE_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :assignment_id }, allow_nil: true

  def display_name
    user&.full_name.presence || name
  end

  def contact_email
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

  def transition_from_pending!(next_status, actor:, timestamp:)
    with_lock do
      raise InvalidTransition, "only pending proposals can transition" unless status == "pending"

      update!(status: next_status, timestamp => Time.current)
      audit_events.create!(actor_user: actor, firm: actor.primary_firm, action: "proposal.#{next_status}")
    end
  end
end
