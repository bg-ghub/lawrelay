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

  test "admin requires an MFA-confirmed current session" do
    @account.user.update!(system_role: "admin")

    post email_change_path(locale: :en), params: { email_change: { email_address: "changed@example.test", current_password: "password1234" } }

    assert_redirected_to admin_mfa_setup_path(locale: :en)
    assert_equal @account.user.email_address, @account.user.reload.email_address
  end

  test "MFA-confirmed admin changes email without a professional profile or firm" do
    user = User.create!(
      email_address: "operator-no-profile@example.test", password: "password1234",
      first_name: "Operator", last_name: "Admin", locale: "en", system_role: "admin",
      email_verified_at: Time.current
    )
    sign_in_as(user, admin_mfa: true)

    assert_enqueued_emails 1 do
      post email_change_path(locale: :en), params: { email_change: { email_address: "operator-new@example.test", current_password: "password1234" } }
    end

    assert_redirected_to admin_users_path(locale: :en)
    assert_equal "operator-new@example.test", user.reload.email_address
    assert_nil user.email_verified_at
    assert_nil user.lawyer_profile
  end
end
