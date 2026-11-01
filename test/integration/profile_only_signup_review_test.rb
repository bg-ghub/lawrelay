require "test_helper"
require_relative "../support/marketplace_test_factory"

class ProfileOnlySignupReviewTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  test "an inline alternate signup needs mailbox confirmation and administrator approval without an explanation" do
    profile_id = SecureRandom.uuid
    source_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}"
    source = Directory::SignupProfile::Result.new(status: :ok, profile_url: source_url,
      name: "Alex Example", first_name: "Alex", last_name: "Example",
      email_address: "listed-signup@example.test", profile_attributes: { spoken_languages: %w[NL FR] })
    password = "Synthetic-signup-password1!"

    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      post registration_path(locale: :en), params: { registration: {
        directory_profile_url: source_url, directory_preview_token: Directory::SignupPreview.issue(source),
        password:, password_confirmation: password, terms_accepted: "1", request_alternative_email: "1",
        alternative_email_address: "working-signup@example.test"
      } }
    end
    assert_redirected_to verification_status_path(locale: :en)
    user = User.find_by!(email_address: "working-signup@example.test")
    assert_equal source.name, user.full_name
    assert_not user.marketplace_verified?

    assert_nil user.reload.lawyer_profile.email_review_request_reason
    assert user.lawyer_profile.email_review_pending?
    perform_enqueued_jobs(only: EmailVerificationDeliveryJob)
    assert_equal [ "working-signup@example.test" ], ActionMailer::Base.deliveries.last.to

    lookup = ->(**) { Directory::AdvocaatBeProfileLookup::Result.new(status: :ok,
      profile_id:, source_url:, name: source.name, email: source.email_address, checked_at: Time.current) }
    assert_no_enqueued_jobs only: Directory::ConfirmationJob do
      Directory::Verification.request!(user:, lookup:)
    end
    post confirm_email_verification_path(token: user.reload.email_verification_token, locale: :en)
    assert user.reload.email_verified?
    assert_not user.marketplace_verified?
    get new_assignment_path(locale: :en)
    assert_redirected_to verification_status_path(locale: :en)

    admin = create_marketplace_account(prefix: "source-only-reviewer", system_role: "admin").user
    secret = admin.begin_admin_mfa_setup!
    admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_in_as(admin, admin_mfa: true)
    get admin_email_review_path(user, locale: :en)
    assert_response :success
    assert_select "button[value='approve']:not([disabled])"
    patch admin_email_review_path(user, locale: :en), params: { decision: "approve", email_review: {
      note: "Checked the independently published professional contact.", identity_checked: "1",
      identity_digest: user.reload.lawyer_profile.email_review_current_identity_digest
    } }
    assert_redirected_to admin_email_review_path(user, locale: :en)
    assert user.reload.marketplace_verified?
    assert user.lawyer_profile.email_review_approved?
    assert_nil user.lawyer_profile.directory_email_verified_at
    assert_nil user.lawyer_profile.email_review_request_reason
  end
end
