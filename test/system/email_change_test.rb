require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class EmailChangeTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "email-system-#{SecureRandom.hex(5)}")
    # Keep this browser test entirely local: an empty directory URL must not
    # enqueue the directory verification job, which would otherwise contact it.
    @account.profile.update!(directory_profile_url: nil)
  end

  teardown do
    Capybara.reset_sessions!

    user_id = @account&.user&.id
    firm_id = @account&.firm&.id
    return unless user_id

    AuditEvent.where(actor_user_id: user_id).or(AuditEvent.where(firm_id: firm_id)).delete_all
    Notification.where(user_id: user_id).delete_all
    Session.where(user_id: user_id).delete_all
    LawyerProfile.where(user_id: user_id).delete_all
    Membership.where(user_id: user_id).delete_all
    User.where(id: user_id).delete_all
    Firm.where(id: firm_id).delete_all
  end

  test "a member changes email from settings after password validation and stays signed in" do
    sign_in_member

    visit settings_path(locale: :en)
    click_link "Change email"
    assert_current_path email_change_path(locale: :en)
    assert_text @account.user.email_address

    fill_in "New email", with: "changed-#{SecureRandom.hex(5)}@example.test"
    fill_in "Current password", with: "not-the-password"
    assert_no_enqueued_emails do
      click_button "Change email"
      assert_selector ".form-error[role='alert']", text: "Your current password is incorrect."
    end

    assert_selector ".form-error[role='alert']", text: "Your current password is incorrect."
    assert_equal @account.user.email_address, @account.user.reload.email_address

    changed_email = "changed-#{SecureRandom.hex(5)}@example.test"
    fill_in "New email", with: changed_email
    fill_in "Current password", with: "password1234"
    assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ @account.user ] do
      assert_no_enqueued_jobs(only: Directory::VerificationJob) do
        click_button "Change email"
        assert_current_path verification_status_path(locale: :en)
      end
    end

    assert_current_path verification_status_path(locale: :en)
    assert_text "Check your inbox"
    assert_text changed_email
    assert_equal changed_email, @account.user.reload.email_address
    assert_nil @account.user.email_verified_at

    # The current browser session remains usable so the member can finish
    # the confirmation flow without authenticating again.
    visit settings_path(locale: :en)
    assert_current_path settings_path(locale: :en)
    assert_text changed_email
  end

  private

  def sign_in_member
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end
end
