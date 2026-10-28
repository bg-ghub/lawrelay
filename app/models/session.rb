class Session < ApplicationRecord
  LIFETIME = 30.days
  ACTIVITY_WRITE_INTERVAL = 15.minutes
  ADMIN_MFA_LIFETIME = 12.hours

  belongs_to :user

  before_validation :set_expiry, on: :create

  validates :expires_at, presence: true

  def expired?(at: Time.current)
    expires_at <= at
  end

  def record_activity!(at: Time.current)
    return if last_seen_at.present? && last_seen_at > ACTIVITY_WRITE_INTERVAL.ago

    update_columns(last_seen_at: at, updated_at: at)
  end

  def admin_mfa_verified?(at: Time.current)
    admin_mfa_verified_at.present? && admin_mfa_verified_at > ADMIN_MFA_LIFETIME.ago(at)
  end

  def mark_admin_mfa_verified!(at: Time.current)
    update_columns(admin_mfa_verified_at: at, admin_mfa_challenged_at: at, updated_at: at)
  end

  private

  def set_expiry
    self.expires_at ||= LIFETIME.from_now
    self.last_seen_at ||= Time.current
  end
end
