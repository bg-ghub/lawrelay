require "test_helper"

class AdminMfaTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(
      email_address: "mfa-admin-#{SecureRandom.hex(4)}@example.test",
      password: "password1234",
      first_name: "Mfa",
      last_name: "Admin",
      locale: "en",
      system_role: "admin",
      email_verified_at: Time.current
    )
  end

  test "encrypts the TOTP secret and rejects replayed codes" do
    secret = @admin.begin_admin_mfa_setup!
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now

    refute_includes @admin.admin_mfa_pending_secret_ciphertext, secret
    @admin.enable_admin_mfa!(code)

    assert_predicate @admin, :admin_mfa_configured?
    assert_nil @admin.admin_mfa_pending_secret_ciphertext
    assert_raises(User::InvalidAdminMfaCode) { @admin.verify_admin_mfa_code!(code) }
  end

  test "session MFA approval expires after twelve hours" do
    session = @admin.sessions.create!
    session.mark_admin_mfa_verified!(at: 11.hours.ago)
    assert_predicate session, :admin_mfa_verified?

    session.update!(admin_mfa_verified_at: 12.hours.ago - 1.second)
    assert_not_predicate session, :admin_mfa_verified?
  end

  test "configured MFA requires an explicit reset before enrollment can restart" do
    secret = @admin.begin_admin_mfa_setup!
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
    @admin.enable_admin_mfa!(code)
    original_ciphertext = @admin.admin_mfa_secret_ciphertext

    assert_raises(User::InvalidAdminMfaCode) { @admin.begin_admin_mfa_setup! }
    assert_raises(User::InvalidAdminMfaCode) { @admin.enable_admin_mfa!(code) }
    assert_equal original_ciphertext, @admin.reload.admin_mfa_secret_ciphertext
    assert_nil @admin.admin_mfa_pending_secret_ciphertext

    @admin.reset_admin_mfa!
    new_secret = @admin.begin_admin_mfa_setup!
    assert_not_equal secret, new_secret
    @admin.enable_admin_mfa!(ROTP::TOTP.new(new_secret, issuer: "LawRelay").now)
    assert_predicate @admin, :admin_mfa_configured?
  end

  test "a stale enrollment cannot replace MFA enabled by another request" do
    secret = @admin.begin_admin_mfa_setup!
    stale_admin = User.find(@admin.id)
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
    @admin.enable_admin_mfa!(code)
    original_ciphertext = @admin.admin_mfa_secret_ciphertext

    assert_raises(User::InvalidAdminMfaCode) { stale_admin.enable_admin_mfa!(code) }
    assert_raises(User::InvalidAdminMfaCode) { stale_admin.begin_admin_mfa_setup! }
    assert_equal original_ciphertext, @admin.reload.admin_mfa_secret_ciphertext
    assert_nil @admin.admin_mfa_pending_secret_ciphertext
  end
end
