require "test_helper"
require_relative "../support/marketplace_test_factory"

class EmailChangeVerificationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  test "a changed official listing and new mailbox restore access without the old mailbox" do
    account = create_marketplace_account(prefix: "updated-directory")
    user = account.user
    profile = account.profile
    source_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
    profile.update!(directory_profile_url: source_url, directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: user.full_name, directory_email: user.email_address, directory_checked_at: Time.current,
      directory_email_verified_at: Time.current, directory_identity_digest: "previous-proof")
    old_email_token = user.email_verification_token
    old_directory_token = Directory::ConfirmationToken.generate(profile)
    sign_in_as(user)

    assert_enqueued_emails 1 do
      post email_change_path(locale: :en), params: {
        email_change: { email_address: "updated-directory@example.test", current_password: "password1234" }
      }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_not user.reload.marketplace_verified?
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { User.find_by_email_verification_token!(old_email_token) }
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(old_directory_token) }

    evidence = Directory::AdvocaatBeProfileLookup::Result.new(status: :ok,
      profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a", source_url:,
      name: user.full_name, email: user.email_address, checked_at: Time.current)
    lookup = Struct.new(:result) { def call(**) = result }.new(evidence)
    assert_no_enqueued_jobs(only: Directory::ConfirmationJob) do
      assert_equal :matched, Directory::Verification.request!(user:, lookup:).status
    end
    assert_not user.reload.marketplace_verified?

    post confirm_email_verification_path(token: user.email_verification_token, locale: :en)

    assert_redirected_to dashboard_path(locale: :en)
    assert_predicate user.reload, :marketplace_verified?
    assert_equal account.firm, user.primary_firm
  end
end
