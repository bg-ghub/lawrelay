require "test_helper"
require_relative "../support/marketplace_test_factory"

class CancellationLocaleTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  test "cancelling an assignment queues one localized email per candidate locale" do
    owner = create_marketplace_account(prefix: "cancellation-owner")
    candidates = %w[nl fr de en].map do |locale|
      candidate = create_marketplace_account(prefix: "cancellation-#{locale}")
      candidate.user.update!(locale: locale)
      candidate
    end
    assignment = create_assignment_for(owner)
    candidates.each { |candidate| create_proposal_for(assignment, candidate) }
    sign_in_as(owner.user)

    assert_enqueued_emails 4 do
      patch cancel_assignment_path(assignment, locale: :en)
    end

    assert_redirected_to dashboard_path(locale: :en)
  end
end
