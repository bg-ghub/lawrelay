require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_password_path(locale: :en)
    assert_response :success
  end

  test "create" do
    post passwords_path(locale: :en), params: { email_address: @user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user ]
    assert_redirected_to new_session_path(locale: :en)

    follow_redirect!
    assert_notice I18n.t("auth.passwords.sent", locale: :en)
  end

  test "create for an unknown user redirects but sends no mail" do
    post passwords_path(locale: :en), params: { email_address: "missing-user@example.com" }
    assert_enqueued_emails 0
    assert_redirected_to new_session_path(locale: :en)

    follow_redirect!
    assert_notice I18n.t("auth.passwords.sent", locale: :en)
  end

  test "edit" do
    get edit_password_path(token: @user.password_reset_token, locale: :en)
    assert_response :success
  end

  test "edit with invalid password reset token" do
    get edit_password_path(token: "invalid token", locale: :en)
    assert_redirected_to new_password_path(locale: :en)

    follow_redirect!
    assert_notice I18n.t("auth.passwords.invalid", locale: :en)
  end

  test "update" do
    assert_changes -> { @user.reload.password_digest } do
      put password_path(token: @user.password_reset_token, locale: :en), params: { password: "new-long-password", password_confirmation: "new-long-password" }
      assert_redirected_to new_session_path(locale: :en)
    end

    follow_redirect!
    assert_notice "password has been reset"
  end

  test "update with non matching passwords" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token: token, locale: :en), params: { password: "no", password_confirmation: "match" }
      assert_redirected_to edit_password_path(token: token, locale: :en)
    end

    follow_redirect!
    assert_notice "at least 12 characters"
  end

  test "an administrator returns to password-only sign-in after a reset without bypassing MFA" do
    @user.update!(system_role: "admin")
    @user.sessions.create!

    put password_path(token: @user.password_reset_token, locale: :en), params: {
      password: "new-long-password", password_confirmation: "new-long-password"
    }

    assert_redirected_to admin_login_path(locale: :en)
    assert_empty @user.reload.sessions
    post admin_login_path(locale: :en), params: { password: "new-long-password" }
    assert_redirected_to admin_users_path(locale: :en)
    follow_redirect!
    assert_redirected_to admin_mfa_setup_path(locale: :en)
  end

  test "short or missing passwords do not reset credentials or revoke sessions" do
    @user.sessions.create!(expires_at: 1.day.from_now)
    token = @user.password_reset_token

    [ {}, { password: "" }, { password: "short", password_confirmation: "short" } ].each do |attributes|
      assert_no_changes -> { @user.reload.password_digest } do
        assert_no_difference "@user.sessions.count" do
          put password_path(token:, locale: :en), params: attributes
        end
      end
      assert_redirected_to edit_password_path(token:, locale: :en)
    end
  end

  test "changing the account email invalidates an outstanding password reset" do
    token = @user.password_reset_token
    @user.update!(email_address: "changed-recovery@example.test")

    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token:, locale: :en), params: { password: "new-long-password", password_confirmation: "new-long-password" }
    end
    assert_redirected_to new_password_path(locale: :en)
  end

  test "request lookup accepts mixed case and surrounding whitespace" do
    post passwords_path(locale: :en), params: { email_address: "  #{@user.email_address.upcase}  " }

    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user ]
    assert_redirected_to new_session_path(locale: :en)
  end

  test "expired links return to the request form with a recovery instruction" do
    token = @user.password_reset_token

    travel 16.minutes do
      get edit_password_path(token:, locale: :en)
    end

    assert_redirected_to new_password_path(locale: :en)
    follow_redirect!
    assert_notice I18n.t("auth.passwords.invalid", locale: :en)
    assert_select "form[action='#{passwords_path(locale: :en)}'] input[type='email']"
  end

  test "a link for a deleted account returns to the request form" do
    token = @user.password_reset_token
    @user.destroy!

    get edit_password_path(token:, locale: :en)

    assert_redirected_to new_password_path(locale: :en)
  end

  private
    def assert_notice(text)
      assert_select "div", /#{text}/
    end
end
