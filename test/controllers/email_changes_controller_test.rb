require "test_helper"
require_relative "../support/marketplace_test_factory"

class EmailChangesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "email-controller")
    sign_in_as(@account.user)
  end

  test "changes a member email only with the current password and sends new-address verification" do
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")

    assert_enqueued_emails 1 do
      assert_enqueued_with(job: Directory::VerificationJob, args: [ @account.user.id ]) do
        post email_change_path(locale: :en), params: { email_change: { email_address: "changed@example.test", current_password: "password1234", system_role: "admin", email_verified_at: Time.current } }
      end
    end

    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "changed@example.test", @account.user.reload.email_address
    assert_not @account.user.system_admin?
    assert_nil @account.user.email_verified_at
  end

  test "wrong password neither changes email nor queues email" do
    assert_no_enqueued_emails do
      post email_change_path(locale: :en), params: { email_change: { email_address: "changed@example.test", current_password: "wrong" } }
    end

    assert_response :unprocessable_content
    assert_equal @account.user.email_address, @account.user.reload.email_address
  end

  test "a saved email change survives mail enqueue failure and still requests the directory check" do
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    original = EmailVerificationMailer.method(:verify)
    EmailVerificationMailer.define_singleton_method(:verify) { |*| raise ActiveJob::EnqueueError, "private mail failure" }
    assert_enqueued_jobs 1, only: Directory::VerificationJob do
      post email_change_path(locale: :en), params: { email_change: { email_address: "retry-change@example.test", current_password: "password1234" } }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "retry-change@example.test", @account.user.reload.email_address
    assert_not @account.user.email_verified?
    assert_equal I18n.t("email_change.notices.updated", locale: :en), flash[:notice]
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :en), flash[:alert]
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  test "administrators cannot view or submit an email change regardless of MFA" do
    @account.user.update!(system_role: "admin")

    [ false, true ].each do |mfa_verified|
      sign_in_as(@account.user, admin_mfa: mfa_verified)
      original_user = @account.user.reload.attributes
      original_profile = @account.profile.reload.attributes
      session_ids = @account.user.sessions.pluck(:id).sort

      assert_no_difference "AuditEvent.count" do
        assert_no_enqueued_jobs do
          get email_change_path(locale: :en)
          assert_response :forbidden
          assert_select "form", count: 0
          post email_change_path(locale: :en), params: { email_change: { email_address: "changed@example.test", current_password: "password1234" } }
          assert_response :forbidden
        end
      end
      assert_equal original_user, @account.user.reload.attributes
      assert_equal original_profile, @account.profile.reload.attributes
      assert_equal session_ids, @account.user.sessions.pluck(:id).sort
    end
  end

  test "administrator without a professional profile cannot change credentials" do
    user = User.create!(
      email_address: "operator-no-profile@example.test", password: "password1234",
      first_name: "Operator", last_name: "Admin", locale: "en", system_role: "admin",
      email_verified_at: Time.current
    )
    sign_in_as(user, admin_mfa: true)

    original_user = user.attributes
    session_ids = user.sessions.pluck(:id)
    assert_no_enqueued_emails do
      get email_change_path(locale: :en)
      assert_response :forbidden
      post email_change_path(locale: :en), params: { email_change: { email_address: "operator-new@example.test", current_password: "password1234" } }
    end

    assert_response :forbidden
    assert_equal original_user, user.reload.attributes
    assert_equal session_ids, user.sessions.pluck(:id)
    assert_nil user.lawyer_profile
  end
end
