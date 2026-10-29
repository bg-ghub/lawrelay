require "test_helper"
require_relative "../support/marketplace_test_factory"

class CancellationLocaleTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  test "cancelling an assignment delivers individually in each candidate's language" do
    owner = create_marketplace_account(prefix: "cancellation-owner")
    candidates = %w[nl fr de en].map do |locale|
      candidate = create_marketplace_account(prefix: "cancellation-#{locale}")
      candidate.user.update!(locale: locale)
      candidate
    end
    assignment = create_assignment_for(owner)
    candidates.each { |candidate| create_proposal_for(assignment, candidate) }
    sign_in_as(owner.user)
    clear_enqueued_jobs
    ActionMailer::Base.deliveries.clear

    perform_enqueued_jobs(only: NotificationEmailDeliveryJob) do
      assert_difference(-> { ActionMailer::Base.deliveries.length }, 4) do
        patch cancel_assignment_path(assignment, locale: :en)
      end
    end

    assert_redirected_to dashboard_path(locale: :en)
    candidates.each do |candidate|
      mail = ActionMailer::Base.deliveries.find { |message| message.to == [ candidate.user.email_address ] }
      assert mail
      assert_nil mail.bcc
      assert_equal I18n.t("workflow.mailers.assignment_cancelled.subject", locale: candidate.user.locale, title: assignment.title), mail.subject
      assert_includes mail.text_part.body.decoded, "/#{candidate.user.locale}/assignments/#{assignment.id}"
    end
  ensure
    ActionMailer::Base.deliveries.clear
  end
end
