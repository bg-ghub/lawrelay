require "test_helper"

class DirectoryVerificationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = users(:one)
    @user.update!(first_name: "Jane", last_name: "Lawyer", email_address: "login@example.test", email_verified_at: nil)
    @profile = LawyerProfile.create!(
      user: @user, bar_association: "OVB", bar_number: "TEST-#{SecureRandom.hex(5)}",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: "Jane Lawyer", directory_email: "directory@example.test",
      directory_checked_at: Time.current, directory_identity_digest: "identity"
    )
    @token = Directory::ConfirmationToken.generate(@profile)
  end

  test "GET renders review page without confirming the professional email" do
    get directory_verification_path(token: @token, locale: :en)

    assert_response :success
    assert_includes response.body, "login@example.test"
    refute @profile.reload.directory_email_verified?
  end

  test "POST explicitly confirms a valid directory email token" do
    post confirm_directory_verification_path(token: @token, locale: :en)

    assert_redirected_to new_session_path(locale: :en)
    assert_predicate @profile.reload, :directory_email_verified?
  end

  test "stale token does not confirm" do
    @user.update!(first_name: "Changed")

    post confirm_directory_verification_path(token: @token, locale: :en)

    assert_redirected_to new_session_path(locale: :en)
    refute @profile.reload.directory_email_verified?
  end
end
