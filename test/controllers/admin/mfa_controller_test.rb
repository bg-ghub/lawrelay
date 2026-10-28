require "test_helper"

class Admin::MfaControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email_address: "mfa-controller-#{SecureRandom.hex(4)}@example.test",
      password: "password1234",
      first_name: "Mfa",
      last_name: "Controller",
      locale: "en",
      system_role: "admin",
      email_verified_at: Time.current
    )
    sign_in_as(@admin)
    @session_id = Current.session.id
  end

  test "unconfigured admin is sent to setup before administration" do
    get "/en/admin/verifications"

    assert_redirected_to "/en/admin/mfa/setup"
  end

  test "setup confirms MFA and grants the current session access" do
    get "/en/admin/mfa/setup"
    secret = @admin.reload.admin_mfa_pending_secret
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now

    assert_difference("AuditEvent.where(action: 'admin.mfa_enabled').count", 1) do
      post "/en/admin/mfa/setup", params: { mfa_code: code }
    end

    assert_predicate @admin.reload, :admin_mfa_configured?
    assert Session.find(@session_id).admin_mfa_verified?
  end

  test "configured admin must complete a fresh MFA challenge" do
    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 1.minute.ago)

    get "/en/admin/verifications"
    assert_redirected_to "/en/admin/mfa/challenge"

    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
    post "/en/admin/mfa/challenge", params: { mfa_code: code }

    assert_redirected_to "/en/admin/verifications"
    assert Session.find(@session_id).admin_mfa_verified?
  end
end
