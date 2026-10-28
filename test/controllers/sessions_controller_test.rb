require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_session_path(locale: :en)
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path(locale: :en), params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to dashboard_path(locale: :en)
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path(locale: :en), params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path(locale: :en)
    assert_nil cookies[:session_id]
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path(locale: :en)

    assert_redirected_to new_session_path(locale: :en)
    assert_empty cookies[:session_id]
  end

  test "expired sessions are rejected and removed" do
    expired_session = @user.sessions.create!(expires_at: 1.minute.ago)
    cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
    cookie_jar.signed[:session_id] = expired_session.id
    cookies["session_id"] = cookie_jar[:session_id]

    get dashboard_path(locale: :en)

    assert_redirected_to new_session_path(locale: :en)
    assert_not Session.exists?(expired_session.id)
  end

  test "suspended accounts cannot sign in even with the correct password" do
    @user.update!(suspended_at: Time.current)
    assert_no_difference "Session.count" do
      post session_path(locale: :en), params: { email_address: @user.email_address, password: "password" }
    end
    assert_redirected_to new_session_path(locale: :en)
    assert_nil cookies[:session_id]
  end

  test "an existing cookie cannot resume an account suspended outside the normal action" do
    sign_in_as(@user)
    session_id = Current.session.id
    @user.update!(suspended_at: Time.current)
    get dashboard_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert_not Session.exists?(session_id)
  end

  test "administrators land on user management without a professional profile" do
    @user.update!(system_role: "admin")
    post session_path(locale: :en), params: { email_address: @user.email_address, password: "password" }
    assert_redirected_to admin_users_path(locale: :en)
  end

  test "administrator sign-in preserves an explicit requested destination" do
    @user.update!(system_role: "admin")
    get "/fr/admin/verifications"
    post session_path(locale: :fr), params: { email_address: @user.email_address, password: "password" }
    assert_redirected_to "http://www.example.com/fr/admin/verifications"
  end
end
