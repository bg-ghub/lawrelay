require "digest"

class LawyerProfile < ApplicationRecord
  VERIFICATION_STATUSES = %w[pending verified rejected suspended].freeze
  DIRECTORY_LOOKUP_FAILURES = %w[invalid_url unavailable malformed name_mismatch email_missing already_claimed].freeze

  belongs_to :user

  normalizes :bar_association, :bar_number, with: ->(value) { value.to_s.strip.upcase }
  normalizes :professional_email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :directory_profile_url, with: ->(value) { value.to_s.strip.presence }
  normalizes :directory_email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :availability_note, with: ->(value) { value.to_s.strip.presence }

  before_validation :normalize_matching_preferences

  validates :bar_association, :bar_number, presence: true
  validates :bar_number, uniqueness: { scope: :bar_association }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :bar_admission_year,
    numericality: { only_integer: true, greater_than_or_equal_to: 1900, less_than_or_equal_to: -> { Time.current.year } },
    allow_nil: true
  validates :availability_note, length: { maximum: 500 }, allow_nil: true

  def verified?
    verification_status == "verified" && verified_at.present?
  end

  def directory_matched?
    directory_profile_id.present? && directory_profile_url.present? && directory_name.present? && directory_email.present? && directory_checked_at.present?
  end

  def directory_email_verified?
    directory_email_verified_at.present?
  end

  def directory_confirmation_required?
    directory_matched? && !directory_email_verified? && !directory_email.to_s.casecmp?(user.email_address.to_s)
  end

  def directory_lookup_identity_digest(profile_url: directory_profile_url, full_name: user.full_name)
    Digest::SHA256.hexdigest([ id, profile_url, full_name ].join("\u0000"))
  end

  def directory_lookup_failure
    return unless verification_status == "pending"

    attempt = AuditEvent.where(auditable: self,
      action: %w[verification.directory_lookup_failed verification.directory_matched]).order(id: :desc).first
    return unless attempt&.action == "verification.directory_lookup_failed"

    metadata = attempt.metadata
    return unless metadata.is_a?(Hash) && DIRECTORY_LOOKUP_FAILURES.include?(metadata["status"])
    return unless metadata["identity_digest"] == directory_lookup_identity_digest

    metadata["status"]
  end

  private

  def normalize_matching_preferences
    self.court_preferences = Array(court_preferences)
      .flat_map { |value| value.to_s.split(",") }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end
end
