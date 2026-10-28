require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  test "verifies an email using a signed expiring token and activates the directory check" do
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

  test "sends a signed-in lawyer to their dashboard when verification completes access" do
    user = users(:two)
    firm = Firm.create!(name: "Verified Email Legal", verification_status: "pending")
    user.memberships.create!(firm:, role: "owner")
    user.create_lawyer_profile!(
      bar_association: "OVB", bar_number: "EMAIL-#{SecureRandom.hex(5)}",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: user.full_name, directory_email: user.email_address,
      directory_checked_at: Time.current
    )
    user.update!(email_verified_at: nil)
    sign_in_as(user)

    get email_verification_path(token: user.email_verification_token, locale: :nl)

    assert_redirected_to dashboard_path(locale: :nl)
    assert_predicate user.reload, :marketplace_verified?
  end
end
