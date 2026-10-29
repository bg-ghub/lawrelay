require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class PasswordResetTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "resetmember")
    @member = @account.user
    @member.update!(password: "original-password1234")
    @member.sessions.create!
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Capybara.reset_sessions!
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
    AuditEvent.where(actor_user_id: @member.id).delete_all
    @member.destroy!
    @account.firm.destroy!
  end

  test "a member recovers from an expired link and signs in with a fresh password" do
    assert_equal :test, ActionMailer::Base.delivery_method
    expired_token = @member.password_reset_token

    travel 16.minutes do
      visit edit_password_path(token: expired_token, locale: :en)
      assert_current_path new_password_path(locale: :en)
      assert_text I18n.t("auth.passwords.invalid", locale: :en)
      assert_selector "label", text: I18n.t("auth.passwords.new.form_title", locale: :en)

      perform_enqueued_jobs do
        fill_in "email_address", with: "  #{@member.email_address.upcase}  "
        click_button I18n.t("auth.passwords.new.submit", locale: :en)
        assert_current_path new_session_path(locale: :en)
      end

      mail = ActionMailer::Base.deliveries.find { |message| message.to == [ @member.email_address ] }
      assert mail, "The reset request must deliver a captured email"
      reset_url = mail.text_part.body.decoded[%r{https?://[^\s]+/en/passwords/[^\s]+/edit}]
      assert reset_url, "The reset email must contain a working link"
      visit URI.parse(reset_url).request_uri
      assert_selector "#password"
      fill_in "password", with: "replacement-password1234"
      fill_in "password_confirmation", with: "replacement-password1234"
      click_button I18n.t("auth.passwords.edit.submit", locale: :en)

      assert_current_path new_session_path(locale: :en)
      assert_empty @member.reload.sessions
      assert_not @member.authenticate("original-password1234")
      assert @member.authenticate("replacement-password1234")
      assert_nil User.find_by_password_reset_token(expired_token)

      fill_in "email_address", with: @member.email_address
      fill_in "password", with: "replacement-password1234"
      click_button I18n.t("auth.sessions.submit", locale: :en)
      assert_current_path dashboard_path(locale: :en)
    end
  end
end
