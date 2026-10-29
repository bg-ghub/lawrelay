class PrivacyRequest < ApplicationRecord
  KINDS = %w[access_export correction deletion restriction objection].freeze
  STATUSES = %w[pending in_review completed rejected].freeze

  belongs_to :user
  belongs_to :handled_by_user, class_name: "User", optional: true
  has_many :audit_events, as: :auditable, dependent: :destroy

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :details, presence: true, length: { maximum: 2_000 }
  validates :resolution_note, length: { maximum: 2_000 }, allow_blank: true

  def reopen!(reviewer:)
    with_lock do
      update!(status: "in_review", handled_by_user: reviewer, resolution_note: nil, resolved_at: nil)
    end
  end

  def close!(status:, reviewer:, note:)
    raise ArgumentError, "invalid terminal status" unless status.in?(%w[completed rejected])

    update!(status: status, handled_by_user: reviewer, resolution_note: note, resolved_at: Time.current)
  end
end
