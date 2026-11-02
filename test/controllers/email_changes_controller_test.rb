require "test_helper"
require_relative "../support/marketplace_test_factory"

class EmailChangesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "email-controller")
    sign_in_as(@account.user)
  end

  test "the legacy page offers support by email without an editable form in all languages" do
    %i[nl fr de en].each do |locale|
      get email_change_path(locale:)
      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "a[href^='mailto:support@lawrelay.be']", text: "support@lawrelay.be"
      assert_select ".settings-page form", count: 0
      assert_select "input[name^='email_change[']", count: 0
      assert_no_match(/translation missing/i, response.body)
    end
  end

  test "legacy submissions preserve account profile sessions and email proof without sending mail" do
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes
    session_ids = @account.user.sessions.pluck(:id).sort
    [ "password1234", "wrong" ].each do |password|
      assert_no_difference "AuditEvent.count" do
        assert_no_enqueued_jobs do
          post email_change_path(locale: :en), params: { email_change: {
            email_address: "changed@example.test", current_password: password, system_role: "admin", email_verified_at: nil
          } }
        end
      end
      assert_response :see_other
      assert_redirected_to email_change_path(locale: :en)
      assert_equal original_user, @account.user.reload.attributes
      assert_equal original_profile, @account.profile.reload.attributes
      assert_equal session_ids, @account.user.sessions.pluck(:id).sort
    end
  end

  test "support mailbox configuration is used for the contact link" do
    previous = ENV["LAWRELAY_SUPPORT_EMAIL"]
    ENV["LAWRELAY_SUPPORT_EMAIL"] = "support-alias@example.test"
    get email_change_path(locale: :en)
    assert_select "a[href^='mailto:support-alias@example.test']", text: "support-alias@example.test"
  ensure
    previous.nil? ? ENV.delete("LAWRELAY_SUPPORT_EMAIL") : ENV["LAWRELAY_SUPPORT_EMAIL"] = previous
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
