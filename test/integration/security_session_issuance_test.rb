require "test_helper"

class SecuritySessionIssuanceTest < ActionDispatch::IntegrationTest
  test "a login authenticated before a password reset cannot issue a session afterward" do
    user = users(:one)
    reset_completed = false
    original = User.method(:authenticate_by)
    reset_password = ->(candidate) do
      recovery = open_session
      recovery.patch password_path(token: candidate.password_reset_token, locale: :en), params: {
        password: "recovered-account-password", password_confirmation: "recovered-account-password"
      }
      assert recovery.response.redirect?
      reset_completed = true
    end
    User.define_singleton_method(:authenticate_by) do |attributes|
      candidate = original.call(attributes)
      reset_password.call(candidate) if candidate
      candidate
    end

    assert_no_difference "Session.count" do
      post session_path(locale: :en), params: { email_address: user.email_address, password: "password" }
    end
    assert reset_completed
    assert_not user.reload.authenticate("password")
    assert user.authenticate("recovered-account-password")
    assert_redirected_to new_session_path(locale: :en)
    assert_nil cookies[:session_id]
    get settings_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
  ensure
    User.define_singleton_method(:authenticate_by, original) if original
  end

  test "an email change between authentication and session creation rejects the old identity" do
    user = users(:one)
    original = User.method(:authenticate_by)
    User.define_singleton_method(:authenticate_by) do |attributes|
      candidate = original.call(attributes)
      User.find(candidate.id).update!(email_address: "changed-before-session@example.test") if candidate
      candidate
    end

    assert_no_difference "Session.count" do
      post session_path(locale: :en), params: { email_address: user.email_address, password: "password" }
    end
    assert_redirected_to new_session_path(locale: :en)
    assert_nil cookies[:session_id]
  ensure
    User.define_singleton_method(:authenticate_by, original) if original
  end

  test "admin credential rotation also rejects an already authenticated stale login" do
    user = users(:one)
    user.update!(system_role: "admin")
    original = Admin::LoginAccount.method(:authenticate)
    Admin::LoginAccount.define_singleton_method(:authenticate) do |password|
      candidate = original.call(password)
      User.find(candidate.id).update!(password: "rotated-admin-password", password_confirmation: "rotated-admin-password") if candidate
      candidate
    end

    assert_no_difference "Session.count" do
      post admin_login_path(locale: :en), params: { password: "password" }
    end
    assert_response :unprocessable_content
    assert_nil cookies[:session_id]
    assert_not user.reload.authenticate("password")
  ensure
    Admin::LoginAccount.define_singleton_method(:authenticate, original) if original
  end
end
