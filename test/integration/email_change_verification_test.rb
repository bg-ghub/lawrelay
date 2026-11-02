require "test_helper"
require_relative "../support/marketplace_test_factory"

class EmailChangeVerificationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  test "a support-reviewed change needs the updated official listing and new mailbox" do
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
      support_change_email(user, "updated-directory@example.test")
    end
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

  test "a different sign-in email cannot bypass manual review through the ordinary change and old-inbox confirmation routes" do
    account = create_marketplace_account(prefix: "different-directory")
    user = account.user
    profile = account.profile
    official_email = user.email_address
    source_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
    profile.update!(directory_profile_url: source_url, directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: user.full_name, directory_email: official_email, directory_checked_at: Time.current,
      directory_email_verified_at: Time.current, directory_identity_digest: "previous-proof")
    sign_in_as(user)

    support_change_email(user, "different-signin@example.test")
    user.reload
    evidence = Directory::AdvocaatBeProfileLookup::Result.new(status: :ok,
      profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a", source_url:,
      name: user.full_name, email: official_email, checked_at: Time.current)
    lookup = Struct.new(:result) { def call(**) = result }.new(evidence)
    assert_no_enqueued_jobs(only: Directory::ConfirmationJob) do
      assert_equal :matched, Directory::Verification.request!(user:, lookup:).status
    end

    legacy_token = Directory::ConfirmationToken.generate(profile.reload)
    post confirm_email_verification_path(token: user.email_verification_token, locale: :en)
    assert_redirected_to verification_status_path(locale: :en)
    post confirm_directory_verification_path(token: legacy_token, locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert user.reload.email_verified?
    assert profile.reload.directory_email_verified?
    assert_not profile.verified?
    assert_not user.marketplace_verified?

    get verification_status_path(locale: :en)
    assert_response :success
    assert_select "h2", text: I18n.t("directory_onboarding.status.review_required_title", locale: :en)
    assert_select "a[href='#{email_access_request_path(locale: :en)}']", text: I18n.t("directory_onboarding.status.request_review", locale: :en)
    assert_no_difference "Assignment.count" do
      post assignments_path(locale: :en), params: { assignment: { title: "Must remain blocked" } }
    end
    assert_redirected_to verification_status_path(locale: :en)
  end

  private

  def support_change_email(user, email)
    administrator = create_marketplace_account(prefix: "support-email-reviewer", system_role: "admin").user
    secret = administrator.begin_admin_mfa_setup!
    administrator.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_in_as(administrator, admin_mfa: true)
    patch admin_user_path(user, locale: :en), params: { user: { email_address: email } }
    assert_redirected_to admin_user_path(user, locale: :en)
    sign_in_as(user)
  end
end
