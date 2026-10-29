require "test_helper"

class TwoFactorAuthenticationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "two-factor-controller-#{SecureRandom.hex(5)}@example.test",
      password: "password1234", first_name: "Two", last_name: "Factor", locale: "en", email_verified_at: Time.current)
    sign_in_as(@user)
    @session_id = Current.session.id
  end

  test "setup needs recent password confirmation and does not create a key on GET" do
    get setup_two_factor_authentication_path(locale: :en)
    assert_redirected_to two_factor_authentication_path(locale: :en)
    assert_nil @user.reload.two_factor_pending_secret_ciphertext

    post begin_setup_two_factor_authentication_path(locale: :en), params: { current_password: "wrong" }
    assert_response :unprocessable_content
    assert_nil @user.reload.two_factor_pending_secret_ciphertext

    begin_setup
    get setup_two_factor_authentication_path(locale: :en)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "img.mfa-qr[src^='data:image/png;base64,']"

    travel 11.minutes do
      get setup_two_factor_authentication_path(locale: :en)
      assert_redirected_to two_factor_authentication_path(locale: :en)
      assert_not_includes response.body, "data:image/png;base64"
    end
  end

  test "a different session cannot see a pending enrollment QR" do
    begin_setup
    sign_in_as(@user)
    get setup_two_factor_authentication_path(locale: :en)
    assert_redirected_to two_factor_authentication_path(locale: :en)
  end

  test "enabling confirms the code revokes other sessions and shows recovery codes once" do
    old_cookie = cookies[:session_id]
    other_session = @user.sessions.create!
    begin_setup
    post enable_two_factor_authentication_path(locale: :en), params: { mfa_code: "invalid" }
    assert_response :unprocessable_content
    assert_not_predicate @user.reload, :two_factor_enabled?

    code = ROTP::TOTP.new(@user.two_factor_pending_secret, issuer: "LawRelay").now
    assert_difference("AuditEvent.where(action: 'account.two_factor_enabled').count", 1) do
      post enable_two_factor_authentication_path(locale: :en), params: { mfa_code: code }
    end
    assert_response :success
    assert_predicate @user.reload, :two_factor_enabled?
    assert_not Session.exists?(other_session.id)
    assert_not Session.exists?(@session_id)
    assert_not_equal old_cookie, cookies[:session_id]
    assert @user.sessions.sole.two_factor_verified?
    assert_select ".recovery-codes code", count: 10
    get two_factor_authentication_path(locale: :en)
    assert_response :success
    assert_select ".recovery-codes code", count: 0
    assert_old_cookie_rejected(old_cookie)
  end

  test "password sign in must complete a second factor before any private route" do
    _, @codes = enable_directly
    sign_out
    post session_path(locale: :en), params: { email_address: @user.email_address, password: "password1234" }
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
    pending_session_id = @user.sessions.sole.id
    pending_cookie = cookies[:session_id]

    get settings_path(locale: :en)
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
    patch settings_path(locale: :en), params: { account: { first_name: "Bypassed" } }
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
    assert_equal "Two", @user.reload.first_name
    delete two_factor_authentication_path(locale: :en), params: { current_password: "password1234", recovery_code: @codes.first }
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
    assert_predicate @user.reload, :two_factor_enabled?

    post verify_two_factor_authentication_path(locale: :en), params: { recovery_code: @codes.first }
    assert_redirected_to "http://www.example.com/en/settings"
    get settings_path(locale: :en)
    assert_response :success
    assert_equal 9, @user.reload.two_factor_recovery_codes_remaining
    assert_not Session.exists?(pending_session_id)
    assert_not_equal pending_cookie, cookies[:session_id]
    assert @user.sessions.sole.two_factor_verified?
    assert_old_cookie_rejected(pending_cookie)
  end

  test "TOTP verification rotates only the pending session" do
    secret, = enable_directly
    pending_cookie = cookies[:session_id]
    other_session = @user.sessions.create!
    other_session.mark_two_factor_verified!

    travel 31.seconds do
      code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
      post verify_two_factor_authentication_path(locale: :en), params: { mfa_code: code }
    end

    assert_redirected_to dashboard_path(locale: :en)
    assert_not Session.exists?(@session_id)
    assert Session.exists?(other_session.id)
    assert_not_equal pending_cookie, cookies[:session_id]
    get settings_path(locale: :en)
    assert_response :success
    assert_old_cookie_rejected(pending_cookie)
  end

  test "invalid second factors do not grant access and logout remains available" do
    enable_directly
    get challenge_two_factor_authentication_path(locale: :en)
    assert_response :success
    post verify_two_factor_authentication_path(locale: :en), params: { mfa_code: "invalid" }
    assert_response :unprocessable_content
    assert_not Session.find(@session_id).two_factor_verified?
    delete session_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert_not Session.exists?(@session_id)
  end

  test "disabling needs password plus second factor and revokes other sessions" do
    _, codes = enable_directly
    Current.session.mark_two_factor_verified!
    old_cookie = cookies[:session_id]
    other_session = @user.sessions.create!

    delete two_factor_authentication_path(locale: :en), params: { current_password: "wrong", recovery_code: codes.first }
    assert_response :unprocessable_content
    assert_predicate @user.reload, :two_factor_enabled?
    delete two_factor_authentication_path(locale: :en), params: { current_password: "password1234", recovery_code: codes.first }
    assert_redirected_to two_factor_authentication_path(locale: :en)
    assert_not_predicate @user.reload, :two_factor_enabled?
    assert_not Session.exists?(other_session.id)
    assert_not Session.exists?(@session_id)
    assert_not_equal old_cookie, cookies[:session_id]
    assert_not_predicate @user.sessions.sole, :two_factor_verified?
    get two_factor_authentication_path(locale: :en)
    assert_response :success
    assert_old_cookie_rejected(old_cookie)
  end

  test "password reset revokes sessions without bypassing the enabled second factor" do
    enable_directly
    token = @user.password_reset_token
    patch password_path(token: token, locale: :en), params: { password: "reset-password1234", password_confirmation: "reset-password1234" }
    assert_redirected_to new_session_path(locale: :en)
    assert_predicate @user.reload, :two_factor_enabled?
    assert_not Session.exists?(@session_id)

    post session_path(locale: :en), params: { email_address: @user.email_address, password: "reset-password1234" }
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
  end

  test "administrator cannot replace mandatory admin MFA with optional member MFA" do
    @user.update!(system_role: "admin")
    post begin_setup_two_factor_authentication_path(locale: :en), params: { current_password: "password1234" }
    assert_redirected_to settings_path(locale: :en)
    assert_nil @user.reload.two_factor_pending_secret_ciphertext
  end

  test "a session revoked after authentication cannot start enrollment or read its setup key" do
    with_authenticated_session_change(-> { Current.session.delete }) do
      post begin_setup_two_factor_authentication_path(locale: :en), params: { current_password: "password1234" }
    end
    assert_revoked_session_rejected
    assert_nil @user.reload.two_factor_pending_secret_ciphertext

    sign_in_as(@user)
    begin_setup
    with_authenticated_session_change(-> { Current.session.delete }) do
      get setup_two_factor_authentication_path(locale: :en)
    end
    assert_revoked_session_rejected
    assert_select "img.mfa-qr", count: 0
  end

  test "a revoked session cannot enable a previously authorized factor" do
    begin_setup
    pending_secret = @user.two_factor_pending_secret_ciphertext
    code = ROTP::TOTP.new(@user.two_factor_pending_secret, issuer: "LawRelay").now

    assert_no_difference("AuditEvent.where(action: 'account.two_factor_enabled').count") do
      with_authenticated_session_change(-> { Current.session.delete }) do
        post enable_two_factor_authentication_path(locale: :en), params: { mfa_code: code }
      end
    end
    assert_revoked_session_rejected
    assert_not_predicate @user.reload, :two_factor_enabled?
    assert_equal pending_secret, @user.two_factor_pending_secret_ciphertext
  end

  test "a revoked pending session cannot consume a recovery code or recreate an approved session" do
    _, codes = enable_directly

    assert_no_difference("AuditEvent.where(action: 'account.two_factor_verified').count") do
      with_authenticated_session_change(-> { Current.session.delete }) do
        post verify_two_factor_authentication_path(locale: :en), params: { recovery_code: codes.first }
      end
    end
    assert_revoked_session_rejected
    assert_equal 10, @user.reload.two_factor_recovery_codes_remaining
  end

  test "a revoked approved session cannot disable two factor authentication" do
    _, codes = enable_directly
    Current.session.mark_two_factor_verified!

    with_authenticated_session_change(-> { Current.session.delete }) do
      delete two_factor_authentication_path(locale: :en), params: { current_password: "password1234", recovery_code: codes.first }
    end
    assert_revoked_session_rejected
    assert_predicate @user.reload, :two_factor_enabled?
    assert_equal 10, @user.two_factor_recovery_codes_remaining
  end

  test "sessions expiring or members suspended during a challenge cannot gain factor approval" do
    _, codes = enable_directly
    changes = [
      -> { Current.session.update_columns(expires_at: 1.second.ago) },
      -> { User.where(id: @user.id).update_all(suspended_at: Time.current) },
      -> { User.where(id: @user.id).update_all(system_role: "admin") }
    ]

    changes.each do |change|
      @user.update!(suspended_at: nil, system_role: "member")
      sign_in_as(@user)
      with_authenticated_session_change(change) do
        post verify_two_factor_authentication_path(locale: :en), params: { recovery_code: codes.first }
      end
      assert_redirected_to new_session_path(locale: :en)
      assert_predicate cookies[:session_id], :blank?
      assert_equal 10, @user.reload.two_factor_recovery_codes_remaining
      assert_not @user.sessions.any?(&:two_factor_verified?)
    end
  end

  private

  def with_authenticated_session_change(change, &request)
    original = TwoFactorAuthenticationsController.instance_method(:require_member)
    TwoFactorAuthenticationsController.define_method(:require_member) do
      original.bind_call(self)
      change.call unless performed?
    end
    TwoFactorAuthenticationsController.send(:private, :require_member)
    request.call
  ensure
    TwoFactorAuthenticationsController.define_method(:require_member, original)
    TwoFactorAuthenticationsController.send(:private, :require_member)
  end

  def assert_revoked_session_rejected
    assert_redirected_to new_session_path(locale: :en)
    assert_predicate cookies[:session_id], :blank?
    assert_empty @user.sessions.reload
  end

  def assert_old_cookie_rejected(cookie)
    open_session do |copied_session|
      copied_session.cookies["session_id"] = cookie
      copied_session.get "/en/settings"
      assert_equal "http://www.example.com/en/session/new", copied_session.response.location
    end
  end

  def begin_setup
    post begin_setup_two_factor_authentication_path(locale: :en), params: { current_password: "password1234" }
    assert_redirected_to setup_two_factor_authentication_path(locale: :en)
    @user.reload
  end

  def enable_directly
    secret = @user.begin_two_factor_setup!(password: "password1234")
    codes = @user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    [ secret, codes ]
  end
end
