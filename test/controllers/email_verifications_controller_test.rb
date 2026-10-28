require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  test "verifies an email using a signed expiring token" do
    user = users(:two)
    user.update!(email_verified_at: nil)

    get email_verification_path(token: user.email_verification_token, locale: :nl)

    assert_redirected_to new_session_path(locale: :nl)
    assert_predicate user.reload, :email_verified?
  end

  test "rejects an invalid verification token" do
    get email_verification_path(token: "not-a-token", locale: :en)

    assert_redirected_to new_session_path(locale: :en)
    assert_equal "This verification link is invalid or has expired.", flash[:alert]
  end
end
