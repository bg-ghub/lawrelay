require "test_helper"
require_relative "../support/marketplace_test_factory"

class ThoroughBetaRegressionTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "an invalid proposal keeps the form and explains the error" do
    owner = create_marketplace_account(prefix: "invalidproposalowner")
    candidate = create_marketplace_account(prefix: "invalidproposalcandidate")
    assignment = create_assignment_for(owner)
    sign_in_as(candidate.user)

    assert_no_difference "Proposal.count" do
      post "/en/assignments/#{assignment.id}/proposals", params: {
        proposal: { rate_cents: "250", message: "" }
      }
    end

    assert_response :unprocessable_content
    assert_select "form.proposal-form"
    assert_select ".form-error", text: /Message/
  end

  test "a proposal cannot be posted after the response cutoff while the hearing is still upcoming" do
    owner = create_marketplace_account(prefix: "cutoffowner")
    candidate = create_marketplace_account(prefix: "cutoffcandidate")
    assignment = create_assignment_for(owner)
    sign_in_as(candidate.user)

    travel_to assignment.response_deadline_at, with_usec: true do
      assert_no_difference [ "Proposal.count", "Notification.count", "AuditEvent.count" ] do
        post "/en/assignments/#{assignment.id}/proposals", params: {
          proposal: { rate_cents: "250", message: "I can attend." }
        }
      end

      assert_redirected_to "/en/assignments/#{assignment.id}"
      follow_redirect!
      assert_select "form.proposal-form", count: 0
    end
  end

  test "an elapsed response window disappears from discovery but remains available to the owner" do
    owner = create_marketplace_account(prefix: "discoveryowner")
    candidate = create_marketplace_account(prefix: "discoverycandidate")
    candidate.profile.update!(practice_areas: [ "Commercial law" ])
    assignment = create_assignment_for(owner, title: "Reply window has closed")
    sign_in_as(candidate.user)

    travel_to assignment.response_deadline_at, with_usec: true do
      get "/en/assignments"
      assert_response :success
      assert_not_includes response.body, assignment.title
      assert_not_includes Matching::AssignmentSuggestions.new(user: candidate.user).call, assignment

      sign_in_as(owner.user)
      get "/en/assignments/#{assignment.id}"
      assert_response :success
      assert_includes response.body, assignment.title
    end
  end

  test "an owner can select an existing proposal after responses close and before the hearing" do
    owner = create_marketplace_account(prefix: "latechoiceowner")
    candidate = create_marketplace_account(prefix: "latechoicecandidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(owner.user)

    travel_to assignment.response_deadline_at, with_usec: true do
      patch "/en/assignments/#{assignment.id}/proposals/#{proposal.id}/accept"

      assert_redirected_to "/en/assignments/#{assignment.id}"
      assert_equal "matched", assignment.reload.status
      assert_equal "accepted", proposal.reload.status
    end
  end

  test "an owner cannot select a proposal once the hearing has started" do
    owner = create_marketplace_account(prefix: "pastchoiceowner")
    candidate = create_marketplace_account(prefix: "pastchoicecandidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(owner.user)

    travel_to assignment.starts_at, with_usec: true do
      assert_no_difference [ "Notification.count", "AuditEvent.count" ] do
        patch "/en/assignments/#{assignment.id}/proposals/#{proposal.id}/accept"
      end

      assert_equal "open", assignment.reload.status
      assert_equal "pending", proposal.reload.status
    end
  end

  test "a new assignment cannot already have reached its response deadline" do
    owner = create_marketplace_account(prefix: "pastdeadlineowner")
    sign_in_as(owner.user)

    assert_no_difference "Assignment.count" do
      post "/en/assignments", params: {
        assignment: assignment_attributes.merge(response_deadline_at: 1.minute.ago)
      }
    end

    assert_response :unprocessable_content
  end

  test "a new hearing cannot be posted in the past" do
    owner = create_marketplace_account(prefix: "pasthearingowner")
    sign_in_as(owner.user)

    assert_no_difference "Assignment.count" do
      post "/en/assignments", params: {
        assignment: assignment_attributes.merge(starts_at: 1.hour.ago, response_deadline_at: 2.hours.ago)
      }
    end

    assert_response :unprocessable_content
  end

  test "the owner can find an overdue matched assignment and older history on the dashboard" do
    owner = create_marketplace_account(prefix: "historyowner")
    matched = create_assignment_for(owner, title: "Hearing awaiting completion", status: "matched")
    matched.update!(starts_at: 1.day.ago, response_deadline_at: 2.days.ago)
    completed = create_assignment_for(owner, title: "Older completed hearing", status: "completed")
    completed.update!(starts_at: 3.days.ago, response_deadline_at: 4.days.ago)
    upcoming = Array.new(5) { |index| create_assignment_for(owner, title: "Upcoming hearing #{index}") }
    sign_in_as(owner.user)

    get "/en/dashboard"

    assert_response :success
    assert_select "a[href='/en/assignments/#{matched.id}']", text: /Hearing awaiting completion/
    assert_select "a[href='/en/assignments/#{completed.id}']", text: /Older completed hearing/
    assert_select ".dashboard-summary .summary-card:nth-child(3) strong", text: upcoming.first.starts_at.strftime("%d/%m")
  end

  %w[not-a-number NaN Infinity 1e1000].each do |amount|
    test "an invalid assignment amount #{amount} is rejected without an exception" do
      owner = create_marketplace_account(prefix: "invalidfeeowner")
      sign_in_as(owner.user)

      assert_no_difference "Assignment.count" do
        post "/en/assignments", params: { assignment: assignment_attributes.merge(fee_cents: amount) }
      end

      assert_response :unprocessable_content
    end

    test "an invalid proposal amount #{amount} is rejected without an exception" do
      owner = create_marketplace_account(prefix: "invalidrateowner")
      candidate = create_marketplace_account(prefix: "invalidratecandidate")
      assignment = create_assignment_for(owner)
      sign_in_as(candidate.user)

      assert_no_difference "Proposal.count" do
        post "/en/assignments/#{assignment.id}/proposals", params: {
          proposal: { rate_cents: amount, message: "I can attend." }
        }
      end

      assert_response :unprocessable_content
      assert_select "form.proposal-form"
      assert_select ".form-error"
    end
  end

  private

  def assignment_attributes
    {
      kind: "court_replacement",
      title: "A bounded hearing",
      description: "A safe description without confidential matter information.",
      city: "Brussels",
      court: "Enterprise Court",
      starts_at: 3.days.from_now,
      response_deadline_at: 2.days.from_now,
      duration_minutes: 60,
      practice_area: "Commercial law",
      fee_cents: "250",
      content_rules_accepted: "1"
    }
  end
end
