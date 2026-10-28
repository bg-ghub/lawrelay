require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  test "a mail scanner GET only shows the confirmation page" do
    user = users(:two)
    user.update!(email_verified_at: nil)
    token = user.email_verification_token

    get email_verification_path(token:, locale: :nl)

    assert_response :success
    assert_not user.reload.email_verified?
    assert_select "form[action='#{confirm_email_verification_path(token:, locale: :nl)}'][method='post']"
  end

  test "explicit POST verifies the account email" do
    user = users(:two)
    user.update!(email_verified_at: nil)

    post confirm_email_verification_path(token: user.email_verification_token, locale: :nl)

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

    token = user.email_verification_token
    get email_verification_path(token:, locale: :nl)
    assert_response :success
    assert_not user.reload.marketplace_verified?
    assert_not user.lawyer_profile.reload.directory_email_verified?

    post confirm_email_verification_path(token:, locale: :nl)

    assert_redirected_to dashboard_path(locale: :nl)
    assert_predicate user.reload, :marketplace_verified?
  end

  test "an old email token cannot verify a changed authoritative email" do
    user = users(:two)
    user.update!(email_verified_at: nil)
    token = user.email_verification_token
    user.update!(email_address: "official@example.test")
    firm = Firm.create!(name: "Pending Legal", verification_status: "pending")
    user.memberships.create!(firm:, role: "owner")
    profile = user.create_lawyer_profile!(
      bar_association: "OVB", bar_number: "TOKEN-#{SecureRandom.hex(5)}",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: user.full_name, directory_email: user.email_address, directory_checked_at: Time.current
    )

    post confirm_email_verification_path(token:, locale: :en)

    assert_redirected_to new_session_path(locale: :en)
    assert_not user.reload.email_verified?
    assert_not user.marketplace_verified?
    assert_not profile.reload.directory_email_verified?
    assert_not firm.reload.verified?
  end
end
