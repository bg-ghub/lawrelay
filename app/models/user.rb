require "digest"

class User < ApplicationRecord
  include TwoFactorAuthenticatable

  class InvalidAdminMfaCode < StandardError; end

  SYSTEM_ROLES = %w[member admin].freeze
  LOCALES = %w[nl fr de en].freeze
  PUBLIC_ID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/.freeze

  attribute :public_id, default: -> { SecureRandom.uuid }
  attr_readonly :public_id

  has_secure_password
  generates_token_for :email_verification, expires_in: 48.hours do
    Digest::SHA256.hexdigest(email_address)
  end
  generates_token_for :password_reset, expires_in: 15.minutes do
    [ Digest::SHA256.hexdigest(email_address), password_salt&.last(10) ]
  end
  before_update :clear_email_verification, if: :will_save_change_to_email_address?
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :firms, through: :memberships
  has_one :lawyer_profile, dependent: :destroy
  has_many :created_assignments, class_name: "Assignment", foreign_key: :creator_user_id, inverse_of: :creator_user, dependent: :restrict_with_error
  has_many :proposals, dependent: :restrict_with_error
  has_many :notifications, dependent: :destroy
  has_many :privacy_requests, dependent: :restrict_with_error
  has_many :submitted_reports, class_name: "Report", foreign_key: :reporter_user_id, inverse_of: :reporter_user, dependent: :restrict_with_error

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :first_name, :last_name, with: ->(value) { value.to_s.strip }

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :public_id, presence: true, uniqueness: true, format: { with: PUBLIC_ID_FORMAT }
  validates :first_name, :last_name, presence: true, length: { maximum: 100 }
  validates :locale, inclusion: { in: LOCALES }
  validates :system_role, inclusion: { in: SYSTEM_ROLES }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :suspension_reason, length: { maximum: 2_000 }, allow_nil: true

  def to_param
    public_id
  end

  def suspended?
    suspended_at.present?
  end

  def active?
    !suspended? && erased_at.nil?
  end

  def full_name
    return I18n.t("retention.deleted_account") if erased_at

    [ first_name, last_name ].compact_blank.join(" ")
  end

  def primary_membership
    memberships.includes(:firm).order(:created_at).first
  end

  def primary_firm
    primary_membership&.firm
  end

  def firm_administrator?(firm = primary_firm)
    memberships.find_by(firm: firm)&.administrator? || false
  end

  def email_verified?
    email_verified_at.present?
  end

  def marketplace_verified?
    !system_admin? && active? && email_verified? && lawyer_profile&.verified? &&
      lawyer_profile.email_review_allows_access? && primary_firm&.verified?
  end

  def system_admin?
    system_role == "admin"
  end

  def admin_mfa_configured?
    admin_mfa_enabled_at.present? && admin_mfa_secret_ciphertext.present?
  end

  def begin_admin_mfa_setup!
    with_lock do
      raise InvalidAdminMfaCode if admin_mfa_configured?
      next admin_mfa_pending_secret if admin_mfa_pending_secret.present?

      secret = ROTP::Base32.random_base32
      update!(admin_mfa_pending_secret_ciphertext: encrypt_admin_mfa_secret(secret))
      secret
    end
  end

  def admin_mfa_pending_secret
    decrypt_admin_mfa_secret(admin_mfa_pending_secret_ciphertext)
  end

  def admin_mfa_provisioning_uri(secret = admin_mfa_pending_secret)
    return if secret.blank?

    ROTP::TOTP.new(secret, issuer: "LawRelay").provisioning_uri(email_address)
  end

  def enable_admin_mfa!(code)
    with_lock do
      raise InvalidAdminMfaCode if admin_mfa_configured?

      secret = admin_mfa_pending_secret
      verified_at = verify_admin_mfa_secret(secret, code)
      raise InvalidAdminMfaCode unless verified_at

      update!(
        admin_mfa_secret_ciphertext: admin_mfa_pending_secret_ciphertext,
        admin_mfa_pending_secret_ciphertext: nil,
        admin_mfa_enabled_at: Time.current,
        admin_mfa_last_verified_at: Time.at(verified_at)
      )
      Time.at(verified_at)
    end
  end

  def verify_admin_mfa_code!(code)
    with_lock do
      verified_at = verify_admin_mfa_secret(admin_mfa_secret, code, after: admin_mfa_last_verified_at)
      raise InvalidAdminMfaCode unless verified_at

      update!(admin_mfa_last_verified_at: Time.at(verified_at))
      Time.at(verified_at)
    end
  end

  def reset_admin_mfa!
    update!(
      admin_mfa_secret_ciphertext: nil,
      admin_mfa_pending_secret_ciphertext: nil,
      admin_mfa_enabled_at: nil,
      admin_mfa_last_verified_at: nil
    )
  end

  def email_verification_token
    generate_token_for(:email_verification)
  end

  def self.find_by_email_verification_token!(token)
    find_by_token_for!(:email_verification, token)
  end

  private

  def clear_email_verification
    self.email_verified_at = nil
    # Include NULL in the SQL even when this object was loaded before another
    # request verified the old address.
    email_verified_at_will_change!
  end

  def admin_mfa_secret
    decrypt_admin_mfa_secret(admin_mfa_secret_ciphertext)
  end

  def verify_admin_mfa_secret(secret, code, after: nil)
    return if secret.blank? || code.to_s.strip.blank?

    ROTP::TOTP.new(secret, issuer: "LawRelay").verify(
      code.to_s.strip,
      drift_behind: 30,
      drift_ahead: 30,
      after: after&.to_i
    )
  end

  def encrypt_admin_mfa_secret(secret)
    self.class.admin_mfa_encryptor.encrypt_and_sign(secret)
  end

  def decrypt_admin_mfa_secret(ciphertext)
    return if ciphertext.blank?

    self.class.admin_mfa_encryptor.decrypt_and_verify(ciphertext)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def self.admin_mfa_encryptor
    @admin_mfa_encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key(
        "lawrelay/admin-mfa-secret/v1",
        ActiveSupport::MessageEncryptor.key_len
      ),
      cipher: "aes-256-gcm"
    )
  end
end
