class RetentionHold < ApplicationRecord
  SUBJECT_TYPES = %w[User Assignment Firm Report PrivacyRequest].freeze

  belongs_to :subject, polymorphic: true
  belongs_to :actor, class_name: "User"

  scope :active, ->(now: Time.current) { where("expires_at > ?", now) }

  validates :subject_type, inclusion: { in: SUBJECT_TYPES }
  validates :reason, presence: true, length: { maximum: 500 }
  validates :expires_at, presence: true
  validate :limited_review_period
  validate :authorised_operator

  private

  def limited_review_period
    return unless expires_at

    errors.add(:expires_at, "must be within the next 90 days") unless expires_at > Time.current && expires_at <= 90.days.from_now
  end

  def authorised_operator
    errors.add(:actor, "must be an active MFA-configured administrator") unless actor&.system_admin? && actor.active? && actor.admin_mfa_configured?
  end
end
