class Report < ApplicationRecord
  CATEGORIES = %w[confidentiality misleading unavailable misconduct other].freeze
  STATUSES = %w[open in_review resolved dismissed].freeze
  REPORTABLE_TYPES = %w[Assignment].freeze

  belongs_to :reporter_user, class_name: "User"
  belongs_to :reportable, polymorphic: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  has_many :audit_events, as: :auditable, dependent: :destroy

  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :reportable_type, inclusion: { in: REPORTABLE_TYPES }
  validates :details, presence: true, length: { maximum: 2_000 }
  validates :resolution_note, length: { maximum: 2_000 }, allow_blank: true
  validate :reporter_is_not_assignment_owner

  def close!(status:, reviewer:, note:)
    raise ArgumentError, "invalid terminal status" unless status.in?(%w[resolved dismissed])

    update!(status: status, reviewed_by_user: reviewer, resolution_note: note, resolved_at: Time.current)
  end

  private

  def reporter_is_not_assignment_owner
    return unless reportable.is_a?(Assignment) && reportable.owned_by?(reporter_user)

    errors.add(:base, I18n.t("trust.reports.errors.own_assignment"))
  end
end
