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

  test "settings sends email changes to support and the old page has no editable form" do
    sign_in_member
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes
    %i[nl fr de en].each do |locale|
      assert_no_enqueued_jobs do
        visit settings_path(locale:)
        assert_link I18n.t("email_change.link", locale:), href: /\Amailto:support@lawrelay\.be\?/
        assert_no_selector "input[name='account[first_name]'], input[name='account[last_name]']", visible: :all
        visit email_change_path(locale:)
        assert_text I18n.t("email_change.lede", locale:)
        assert_link "support@lawrelay.be", href: /\Amailto:support@lawrelay\.be\?/
        assert_no_selector ".settings-page form", visible: :all
      end
    end
    assert_equal original_user, @account.user.reload.attributes
    assert_equal original_profile, @account.profile.reload.attributes
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
