require "test_helper"
require_relative "../support/marketplace_test_factory"

class EmailAccessRequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "access-controller", verified: false, email_verified: false)
    @other = create_marketplace_account(prefix: "access-untouched")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}")
    @reason = "I use this address for my current professional correspondence."
    sign_in_as(@account.user)
  end

  test "a member submits their own new address and receives confirmation through existing mail" do
    assert_enqueued_emails 1 do
      assert_enqueued_with(job: Directory::VerificationJob, args: [ @account.user.id ]) do
        post email_access_request_path(locale: :en), params: {
          email_access: { email_address: "working-controller@example.test", current_password: "password1234",
            reason: @reason,
            user_id: @other.user.id, email_review_status: "approved", email_verified_at: Time.current }
        }
      end
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "working-controller@example.test", @account.user.reload.email_address
    assert_nil @account.user.email_verified_at
    assert @account.profile.reload.email_review_pending?
    assert_nil @account.profile.email_review_request_reason
    assert_nil @other.profile.reload.email_review_status
    assert_not @account.user.marketplace_verified?
  end

  test "a duplicate request does not send duplicate confirmation or verification jobs" do
    parameters = { email_access: { email_address: "working-duplicate@example.test", current_password: "password1234", reason: @reason } }
    post email_access_request_path(locale: :en), params: parameters
    assert_no_enqueued_jobs do
      post email_access_request_path(locale: :en), params: parameters
    end
    assert_redirected_to verification_status_path(locale: :en)
  end

  test "a member can request review without an explanation" do
    assert_enqueued_jobs 2 do
      post email_access_request_path(locale: :en), params: {
        email_access: { email_address: "working-no-reason@example.test", current_password: "password1234" }
      }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "working-no-reason@example.test", @account.user.reload.email_address
    assert @account.profile.reload.email_review_pending?
    assert_nil @account.profile.email_review_request_reason
  end

  test "legacy explanation input is ignored and the request form does not ask for one" do
    get email_access_request_path(locale: :en)
    assert_response :success
    assert_select "textarea[name='email_access[reason]']", count: 0
    post email_access_request_path(locale: :en), params: {
      email_access: { email_address: "working-legacy-reason@example.test", current_password: "password1234", reason: "x" * 1_001 }
    }
    assert_redirected_to verification_status_path(locale: :en)
    assert_nil @account.profile.reload.email_review_request_reason
  end

  test "wrong password leaves the address and sessions untouched" do
    email = @account.user.email_address
    sessions = @account.user.sessions.pluck(:id)
    assert_no_enqueued_jobs do
      post email_access_request_path(locale: :en), params: {
        email_access: { email_address: "working-denied@example.test", current_password: "wrong" }
      }
    end
    assert_response :unprocessable_content
    assert_equal email, @account.user.reload.email_address
    assert_equal sessions, @account.user.sessions.pluck(:id)
    assert_nil @account.profile.reload.email_review_status
  end

  test "a confirmed member must use support instead of changing email through onboarding" do
    @account.user.update!(email_verified_at: Time.current)
    original_user = @account.user.reload.attributes
    original_profile = @account.profile.attributes
    session_ids = @account.user.sessions.pluck(:id)

    assert_no_enqueued_jobs do
      get email_access_request_path(locale: :en)
      assert_redirected_to email_change_path(locale: :en)
      post email_access_request_path(locale: :en), params: {
        email_access: { email_address: "bypass-confirmed@example.test", current_password: "password1234" }
      }
      assert_redirected_to email_change_path(locale: :en)
    end
    assert_equal original_user, @account.user.reload.attributes
    assert_equal original_profile, @account.profile.reload.attributes
    assert_equal session_ids, @account.user.sessions.pluck(:id)
  end

  test "request forms render in all supported languages with no cache" do
    %w[nl fr de en].each do |locale|
      get email_access_request_path(locale:)
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "form[action='#{email_access_request_path(locale:)}']"
      assert_select "textarea[name='email_access[reason]']", count: 0
      assert_select "input[name='email_access[email_address]'][autocomplete='username']"
      assert_not(/translation missing/i.match?(response.body))
    end
  end

  test "a pending member is never prompted to add an explanation" do
    @account.profile.update!(email_review_status: "pending", email_review_email_address: @account.user.email_address,
      email_review_requested_at: Time.current, email_review_request_reason: nil)
    %w[nl fr de en].each do |locale|
      get verification_status_path(locale:)
      assert_response :success
      assert_select "a", text: I18n.t("email_access.status.provide_reason", locale:), count: 0
    end

    @account.profile.update!(email_review_request_reason: @reason)
    get verification_status_path(locale: :en)
    assert_response :success
    assert_select "a", text: I18n.t("email_access.status.provide_reason", locale: :en), count: 0
  end

  test "guests and administrators cannot request member email recovery" do
    sign_out
    get email_access_request_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    @account.user.update!(system_role: "admin")
    sign_in_as(@account.user, admin_mfa: true)
    get email_access_request_path(locale: :en)
    assert_response :forbidden
    post email_access_request_path(locale: :en), params: { email_access: { email_address: "no-admin-change@example.test", current_password: "password1234" } }
    assert_response :forbidden
    assert_nil @account.profile.reload.email_review_status
  end

  test "member two factor remains required before recovery" do
    @account.user.update!(email_verified_at: Time.current)
    secret = @account.user.begin_two_factor_setup!(password: "password1234")
    @account.user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    @account.user.update!(email_verified_at: nil)
    sign_in_as(@account.user)
    get email_access_request_path(locale: :en)
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
  end

  test "cross-site submissions are rejected" do
    previous = EmailAccessRequestsController.allow_forgery_protection
    EmailAccessRequestsController.allow_forgery_protection = true
    assert_no_enqueued_jobs do
      post email_access_request_path(locale: :en), params: {
        email_access: { email_address: "cross-site@example.test", current_password: "password1234" }
      }, headers: { "Origin" => "https://unrelated.example" }
    end
    assert_response :unprocessable_content
    assert_nil @account.profile.reload.email_review_status
  ensure
    EmailAccessRequestsController.allow_forgery_protection = previous
  end
end
