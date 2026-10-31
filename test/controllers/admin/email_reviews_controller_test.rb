require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::EmailReviewsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "review-console", verified: false)
    @profile = @account.profile
    @profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_profile_id: SecureRandom.uuid, directory_name: @account.user.full_name,
      directory_email: "listed@example.test", directory_checked_at: 1.minute.ago,
      email_review_status: "pending", email_review_email_address: @account.user.email_address,
      email_review_requested_at: 2.minutes.ago)
    @admin = create_marketplace_account(prefix: "review-console-admin", system_role: "admin").user
    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_in_as(@admin, admin_mfa: true)
  end

  test "admin lists and views the pending request in each language" do
    %w[nl fr de en].each do |locale|
      get admin_email_reviews_path(locale:)
      assert_response :success
      assert_select "a[href='#{admin_email_review_path(@account.user, locale:)}']"
      get admin_email_review_path(@account.user, locale:)
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_not(/translation missing/i.match?(response.body))
    end
  end

  test "approval requires MFA and member accounts never see the console" do
    sign_in_as(@admin)
    patch admin_email_review_path(@account.user, locale: :en), params: review_params
    assert_redirected_to admin_mfa_challenge_path(locale: :en)
    sign_in_as(@account.user)
    get admin_email_reviews_path(locale: :en)
    assert_redirected_to root_path(locale: :en)
    patch admin_email_review_path(@account.user, locale: :en), params: review_params
    assert_redirected_to root_path(locale: :en)
    assert @profile.reload.email_review_pending?
  end

  test "approval records the reviewed identity and queues one decision message" do
    assert_enqueued_with(job: EmailAccessReviewDeliveryJob) do
      patch admin_email_review_path(@account.user, locale: :en), params: review_params
    end
    assert_redirected_to admin_email_review_path(@account.user, locale: :en)
    assert @account.user.reload.marketplace_verified?
    assert_nil @profile.reload.directory_email_verified_at
    assert_equal @admin.id, @profile.email_reviewed_by_user_id
    assert AuditEvent.exists?(auditable: @profile, actor_user: @admin, action: "email_access.approved")
    assert_no_enqueued_jobs do
      patch admin_email_review_path(@account.user, locale: :en), params: review_params
    end
    assert_response :unprocessable_content
  end

  test "forged approval without attestation or email confirmation remains blocked" do
    parameters = review_params
    parameters[:email_review].delete(:identity_checked)
    assert_no_enqueued_jobs do
      patch admin_email_review_path(@account.user, locale: :en), params: parameters
    end
    assert_response :unprocessable_content
    @account.user.update!(email_verified_at: nil)
    patch admin_email_review_path(@account.user, locale: :en), params: review_params
    assert_response :unprocessable_content
    assert @profile.reload.email_review_pending?
    assert_not @account.user.reload.marketplace_verified?
  end

  test "generic professional approval cannot bypass a pending email review" do
    patch admin_verification_path(@account.user, locale: :en), params: { decision: "approve", verification: { note: "Generic review" } }
    assert_redirected_to admin_email_review_path(@account.user, locale: :en)
    assert @profile.reload.email_review_pending?
    assert_not @account.user.reload.marketplace_verified?
  end

  test "stale directory evidence and protected accounts cannot be approved" do
    @profile.update!(directory_checked_at: 3.minutes.ago)
    patch admin_email_review_path(@account.user, locale: :en), params: review_params
    assert_response :unprocessable_content
    @profile.update!(directory_checked_at: Time.current)
    @account.user.update!(suspended_at: Time.current)
    patch admin_email_review_path(@account.user, locale: :en), params: review_params
    assert_response :unprocessable_content
    assert @profile.reload.email_review_pending?
  end

  test "rejection needs a note and does not suspend or grant access" do
    parameters = review_params.merge(decision: "reject")
    parameters[:email_review][:note] = ""
    patch admin_email_review_path(@account.user, locale: :en), params: parameters
    assert_response :unprocessable_content
    parameters[:email_review][:note] = "Independent contact evidence was insufficient."
    patch admin_email_review_path(@account.user, locale: :en), params: parameters
    assert_redirected_to admin_email_review_path(@account.user, locale: :en)
    assert_equal "rejected", @profile.reload.email_review_status
    assert @account.user.reload.active?
    assert_not @account.user.marketplace_verified?
  end

  test "direct routes without an email request do not render a broken review" do
    @profile.update!(email_review_status: nil)
    get admin_email_review_path(@account.user, locale: :en)
    assert_response :not_found
    @profile.destroy!
    get admin_email_review_path(@account.user, locale: :en)
    assert_response :not_found
  end

  test "numeric email review bookmarks redirect to UUIDs without reviewing the request" do
    original_profile = @profile.reload.attributes
    assert_no_enqueued_jobs do
      assert_no_difference "AuditEvent.count" do
        get admin_email_review_path(@account.user.id, locale: :fr)
      end
    end
    assert_response :moved_permanently
    assert_redirected_to admin_email_review_path(@account.user, locale: :fr)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal original_profile, @profile.reload.attributes
  end

  test "legacy numeric review forms retain the identity attestation requirement" do
    parameters = review_params
    parameters[:email_review].delete(:identity_checked)
    assert_no_enqueued_jobs do
      patch admin_email_review_path(@account.user.id, locale: :en), params: parameters
    end
    assert_response :unprocessable_content
    assert_select "a[hreflang='fr'][href='#{admin_email_review_path(@account.user, locale: :fr)}']", count: 1
    assert @profile.reload.email_review_pending?

    patch admin_email_review_path(@account.user.id, locale: :en), params: review_params
    assert_redirected_to admin_email_review_path(@account.user, locale: :en)
    assert @profile.reload.email_review_approved?
  end

  test "email review identifiers never bind through numeric prefixes or unknown UUIDs" do
    [ "#{@account.user.id}extra", SecureRandom.uuid ].each do |identifier|
      assert_no_enqueued_jobs do
        assert_no_difference "AuditEvent.count" do
          patch admin_email_review_path(identifier, locale: :en), params: review_params
        end
      end
      assert_response :not_found
    end
    assert @profile.reload.email_review_pending?
  end

  private

  def review_params
    { decision: "approve", email_review: { note: "Checked the independently published firm contact.",
      identity_checked: "1", identity_digest: @profile.reload.email_review_current_identity_digest } }
  end
end
