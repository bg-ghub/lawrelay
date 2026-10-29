class Assignment < ApplicationRecord
  class InvalidTransition < StandardError; end

  KINDS = {
    court_replacement: "court_replacement",
    legal_task: "legal_task"
  }.freeze
  SUBTYPES = {
    court_replacement: %w[hearing expertise file_review notary plea police_interview adjourned_hearing adjournment_request default_judgment],
    legal_task: %w[advice submissions contract summons petition other]
  }.freeze
  STATUSES = %w[draft open matched completed cancelled expired].freeze

  has_many :proposals, dependent: :destroy
  has_many :audit_events, as: :auditable, dependent: :destroy
  belongs_to :creator_user, class_name: "User", inverse_of: :created_assignments, optional: true
  belongs_to :firm, optional: true

  before_validation :normalize_structured_fields

  validates :kind, inclusion: { in: KINDS.values }
  validates :status, inclusion: { in: STATUSES }
  validates :title, :description, :practice_area, :starts_at, presence: true
  validates :city, presence: true, if: :court_replacement?
  validates :court, presence: true, if: :court_replacement?
  validates :title, length: { maximum: 160 }
  validates :description, length: { maximum: 4_000 }
  validates :city, :practice_area, length: { maximum: 100 }
  validates :court, length: { maximum: 180 }, allow_blank: true
  validates :languages, length: { maximum: 100 }, allow_blank: true
  validates :languages, presence: true, if: :legal_task?
  validates :duration_minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 1_440 }, allow_nil: true
  validates :duration_minutes, presence: true, if: :court_replacement?
  validates :fee_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000_000 }, allow_nil: true
  validates :assignment_subtype, presence: true
  validates :scope_indication, length: { maximum: 250 }, allow_blank: true
  validate :assignment_subtype_matches_kind
  validate :deadline_sequence
  validate :future_deadlines, on: :create
  validate :content_rules_were_accepted, on: :create

  scope :open, -> { where(status: "open") }
  scope :active, -> { where(status: %w[open matched]) }
  scope :upcoming, -> { where(starts_at: Time.current..) }
  scope :accepting_proposals, -> {
    now = Time.current
    open.where("starts_at > :now AND response_deadline_at > :now", now: now)
  }
  scope :ordered, -> { order(urgent: :desc, starts_at: :asc, created_at: :desc) }
  scope :search, ->(query) do
    next all if query.blank?

    term = "%#{sanitize_sql_like(query.strip)}%"
    where("title LIKE :term OR description LIKE :term OR court LIKE :term OR city LIKE :term OR practice_area LIKE :term", term: term)
  end

  def court_replacement?
    kind == KINDS[:court_replacement]
  end

  def legal_task?
    kind == KINDS[:legal_task]
  end

  def kind_label
    I18n.t("assignments.kinds.#{kind}")
  end

  def subtype_label
    I18n.t("marketplace.assignment_subtypes.#{assignment_subtype}")
  end

  def fee_in_euros
    return nil if fee_cents.blank?

    fee_cents / 100.0
  end

  def owned_by?(user)
    user.present? && firm_id.present? && user.firm_ids.include?(firm_id)
  end

  def manageable_by?(user)
    owned_by?(user) && (creator_user_id == user.id || user.firm_administrator?(firm))
  end

  def visible_to?(user)
    return false unless user
    return true if status == "open"

    owned_by?(user) || proposals.exists?(user_id: user.id)
  end

  def accepted_proposal
    proposals.find_by(status: "accepted")
  end

  def accepting_proposals?(now: Time.current)
    status == "open" && starts_at.present? && starts_at > now &&
      response_deadline_at.present? && response_deadline_at > now
  end

  def cancel!(actor:)
    transition_to!("cancelled", actor: actor)
  end

  def complete!(actor:)
    transition_to!("completed", actor: actor)
  end

  # An unattended transition has no human actor. Keep its audit record and the
  # owner's in-app notification in the same database transaction.
  def expire_if_stale!(now: Time.current)
    with_lock do
      next false unless status == "open" && starts_at < now

      update!(status: "expired")
      audit_events.create!(actor_user: nil, firm: firm, action: "assignment.expired")
      creator_user&.notifications&.create!(
        kind: "assignment_expired",
        subject: self,
        data: { assignment_id: id }
      )
      true
    end
  end

  def expire!
    transition_to!("expired", actor: nil)
  end

  private

  def normalize_structured_fields
    self.assignment_subtype ||= court_replacement? ? "hearing" : "advice"
    self.response_deadline_at ||= starts_at&.advance(hours: -1)

    return unless court_replacement?

    self.languages = nil
    self.scope_indication = nil
    self.delivery_due_at = nil
  end

  def assignment_subtype_matches_kind
    return if assignment_subtype.blank? || kind.blank?

    allowed = SUBTYPES.fetch(kind.to_sym, [])
    errors.add(:assignment_subtype, :inclusion) unless assignment_subtype.in?(allowed)
  end

  def deadline_sequence
    return if response_deadline_at.blank? || starts_at.blank?

    errors.add(:response_deadline_at, :before_start) unless response_deadline_at < starts_at
    return unless legal_task? && delivery_due_at.present?

    errors.add(:delivery_due_at, :after_response) if delivery_due_at < response_deadline_at
    errors.add(:delivery_due_at, :before_execution) unless delivery_due_at < starts_at
  end

  def content_rules_were_accepted
    errors.add(:base, I18n.t("workflow.errors.content_rules_required")) if content_rules_accepted_at.blank?
  end

  def future_deadlines
    now = Time.current
    %i[starts_at response_deadline_at].each do |attribute|
      deadline = public_send(attribute)
      errors.add(attribute, :in_future) if deadline.present? && deadline <= now
    end
  end

  def transition_to!(next_status, actor:)
    with_lock do
      allowed = {
        "draft" => %w[open cancelled],
        "open" => %w[matched cancelled expired],
        "matched" => %w[completed cancelled]
      }
      unless next_status.in?(allowed.fetch(status, []))
        raise InvalidTransition, "cannot transition assignment from #{status} to #{next_status}"
      end

      update!(status: next_status)
      audit_events.create!(actor_user: actor, firm: actor&.primary_firm || firm, action: "assignment.#{next_status}")
    end
  end
end
