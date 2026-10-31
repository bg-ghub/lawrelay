require "digest"

class LawyerProfile < ApplicationRecord
  VERIFICATION_STATUSES = %w[pending verified rejected suspended].freeze
  DIRECTORY_LOOKUP_FAILURES = %w[invalid_url unavailable malformed name_mismatch email_missing already_claimed].freeze
  EMAIL_REVIEW_STATUSES = %w[pending approved rejected].freeze
  EMAIL_REVIEW_FIELDS = %w[email_review_status email_review_email_address email_review_requested_at email_reviewed_at
    email_reviewed_by_user_id email_review_note email_review_identity_digest].freeze
  MANUAL_ACTIVATION_FIELDS = %w[manual_activation_approved_at manual_activation_approved_by_user_id manual_activation_identity_digest].freeze
  MANUAL_ACTIVATION_IDENTITY_FIELDS = %w[directory_profile_id directory_profile_url directory_name directory_email].freeze

  belongs_to :user
  belongs_to :email_reviewed_by_user, class_name: "User", optional: true
  belongs_to :manual_activation_approved_by_user, class_name: "User", optional: true

  normalizes :bar_association, :bar_number, with: ->(value) { value.to_s.strip.upcase }
  normalizes :professional_email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :directory_profile_url, with: ->(value) { value.to_s.strip.presence }
  normalizes :directory_email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :availability_note, with: ->(value) { value.to_s.strip.presence }

  before_validation :normalize_matching_preferences
  before_validation :invalidate_changed_manual_activation

  validates :bar_association, :bar_number, presence: true
  validates :bar_number, uniqueness: { scope: :bar_association }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :bar_admission_year,
    numericality: { only_integer: true, greater_than_or_equal_to: 1900, less_than_or_equal_to: -> { Time.current.year } },
    allow_nil: true
  validates :availability_note, length: { maximum: 500 }, allow_nil: true
  validates :email_review_status, inclusion: { in: EMAIL_REVIEW_STATUSES }, allow_nil: true
  validates :email_review_note, length: { maximum: 2_000 }, allow_nil: true

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
    directory_matched? && email_review_status.nil? && !directory_email_verified? && !directory_email.to_s.casecmp?(user.email_address.to_s)
  end

  def email_review_pending?
    email_review_status == "pending"
  end

  def email_review_approved?
    email_review_status == "approved" && email_review_email_address == user.email_address &&
      email_review_identity_digest.present? && email_review_identity_digest == email_review_current_identity_digest
  end

  def email_review_allows_access?
    email_review_status.nil? || email_review_approved?
  end

  def email_review_current_identity_digest
    Digest::SHA256.hexdigest([ user.id, user.full_name, user.email_address, directory_profile_url,
      directory_profile_id, directory_name, directory_email ].join("\u0000"))
  end

  def manual_activation_valid?
    manual_activation_approved_at.present? && manual_activation_approved_by_user_id.present? &&
      manual_activation_identity_digest.present? && manual_activation_identity_digest == email_review_current_identity_digest &&
      user.active? && !user.system_admin? && !verification_status.in?(%w[rejected suspended]) && email_review_allows_access? &&
      directory_matched? && Directory::AdvocaatBeProfileLookup.valid_profile_url?(directory_profile_url) &&
      Directory::AdvocaatBeProfileLookup.names_match?(directory_name, user.full_name) &&
      directory_email.to_s.casecmp?(user.email_address.to_s)
  end

  def clear_manual_activation
    assign_attributes(MANUAL_ACTIVATION_FIELDS.index_with { nil })
  end

  def email_review_directory_ready?
    directory_matched? && email_review_requested_at.present? && directory_checked_at >= email_review_requested_at &&
      Directory::AdvocaatBeProfileLookup.valid_profile_url?(directory_profile_url) &&
      Directory::AdvocaatBeProfileLookup.names_match?(directory_name, user.full_name)
  end

  def clear_email_review
    assign_attributes(EMAIL_REVIEW_FIELDS.index_with { nil })
  end

  def invalidate_changed_email_review
    return unless email_review_status == "approved" && !email_review_approved?

    assign_attributes(email_review_status: "pending", email_review_requested_at: Time.current,
      email_reviewed_at: nil, email_reviewed_by_user_id: nil, email_review_note: nil, email_review_identity_digest: nil)
    assign_attributes(verification_status: "pending", verified_at: nil) unless verification_status.in?(%w[rejected suspended])
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

  def invalidate_changed_manual_activation
    if persisted? && MANUAL_ACTIVATION_IDENTITY_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
      clear_manual_activation
      # A profile may have been loaded before the approval was committed.
      MANUAL_ACTIVATION_FIELDS.each { |field| attribute_will_change!(field) }
    elsif manual_activation_approved_at.present? && !manual_activation_valid?
      clear_manual_activation
    end
  end

  def normalize_matching_preferences
    self.court_preferences = Array(court_preferences)
      .flat_map { |value| value.to_s.split(",") }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end
end
