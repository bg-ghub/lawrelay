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
end
