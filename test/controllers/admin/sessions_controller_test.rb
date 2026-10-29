require "test_helper"

class Admin::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email_address: "admin-login-#{SecureRandom.hex(4)}@example.test",
      password: "password1234",
      first_name: "Admin",
      last_name: "Login",
      locale: "en",
      system_role: "admin",
      email_verified_at: Time.current
    )
    @original_admin_user_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    ENV.delete("LAWRELAY_ADMIN_USER_ID")
  end

  teardown do
    if @original_admin_user_id
      ENV["LAWRELAY_ADMIN_USER_ID"] = @original_admin_user_id
    else
      ENV.delete("LAWRELAY_ADMIN_USER_ID")
    end
  end

  test "login page only exposes a password field" do
    get admin_login_path(locale: :en)

    assert_response :success
    assert_select "input[type='password'][name='password']"
    assert_select "input[type='email']", count: 0
    assert_select "a[href*='/passwords']", count: 0
  end

  test "correct password starts an admin session without bypassing MFA" do
    post admin_login_path(locale: :en), params: { password: "password1234" }

    assert_redirected_to admin_users_path(locale: :en)
    assert cookies[:session_id]

    get admin_users_path(locale: :en)
    assert_redirected_to admin_mfa_setup_path(locale: :en)
  end

  test "invalid password does not create a session" do
    assert_no_difference "Session.count" do
      post admin_login_path(locale: :en), params: { password: "not-the-password" }
    end

    assert_response :unprocessable_content
    assert_nil cookies[:session_id]
    assert_select "input[type='email']", count: 0
  end

  test "configured administrator id remains the login identity when another administrator exists" do
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
    User.create!(
      email_address: "other-admin-#{SecureRandom.hex(4)}@example.test",
      password: "another-password",
      first_name: "Other",
      last_name: "Admin",
      locale: "en",
      system_role: "admin"
    )

    post admin_login_path(locale: :en), params: { password: "password1234" }

    assert_redirected_to admin_users_path(locale: :en)
  end

  test "ambiguous administrator accounts fail closed without a configured id" do
    User.create!(
      email_address: "second-admin-#{SecureRandom.hex(4)}@example.test",
      password: "another-password",
      first_name: "Second",
      last_name: "Admin",
      locale: "en",
      system_role: "admin"
    )

    assert_no_difference "Session.count" do
      post admin_login_path(locale: :en), params: { password: "password1234" }
    end

    assert_response :unprocessable_content
  end

  test "an invalid explicitly configured id fails closed" do
    ENV["LAWRELAY_ADMIN_USER_ID"] = "999999"

    assert_no_difference "Session.count" do
      post admin_login_path(locale: :en), params: { password: "password1234" }
    end

    assert_response :unprocessable_content
  end

  test "inactive configured administrator cannot sign in" do
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
    @admin.update!(suspended_at: Time.current)

    assert_no_difference "Session.count" do
      post admin_login_path(locale: :en), params: { password: "password1234" }
    end

    assert_response :unprocessable_content
  end
end
