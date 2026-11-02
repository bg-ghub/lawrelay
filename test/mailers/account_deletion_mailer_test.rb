require "test_helper"
require_relative "../support/marketplace_test_factory"

class AccountDeletionMailerTest < ActionMailer::TestCase
  include MarketplaceTestFactory
  self.fixture_table_names = []

  test "request and cancellation emails use the member locale salutation and Brussels date" do
    %w[nl fr de en].each do |locale|
      account = create_marketplace_account(prefix: "deletion-mail-#{locale}")
      member = account.user
      member.update!(locale:, last_name: "Van den Berg")
      travel_to Time.utc(2026, 11, 2, 23, 30) do
        request = Accounts::Deletion.schedule!(user: member, current_session: member.sessions.create!, password: "password1234")
        message = AccountDeletionMailer.requested(request).message
        assert_equal [ member.email_address ], message.to
        assert_equal I18n.t("account_deletion_mail.requested.subject", locale:), message.subject
        assert_includes message.text_part.body.decoded, I18n.t("lawyer_titles.salutation", locale:, name: "Van den Berg")
        date = I18n.l(request.scheduled_at.in_time_zone("Europe/Brussels").to_date, format: :long, locale:)
        assert_includes message.text_part.body.decoded, date
        assert_includes message.text_part.body.decoded, SiteHosts.main_url("/#{locale}/session/new")
        assert_no_match(/translation missing/i, message.body.decoded)
        Accounts::Deletion.cancel!(user: member, current_session: member.sessions.create!, password: "password1234")
        cancelled = AccountDeletionMailer.cancelled(request.reload).message
        assert_equal I18n.t("account_deletion_mail.cancelled.subject", locale:), cancelled.subject
        assert_includes cancelled.text_part.body.decoded, I18n.t("lawyer_titles.salutation", locale:, name: "Van den Berg")
        assert_no_match(/translation missing/i, cancelled.body.decoded)
      end
    end
  end
end
