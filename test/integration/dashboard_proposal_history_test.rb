require "test_helper"
require_relative "../support/marketplace_test_factory"

class DashboardProposalHistoryTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @owner = create_marketplace_account(prefix: "dashboard-history-owner")
    @candidate = create_marketplace_account(prefix: "dashboard-history-candidate")
    sign_in_as(@candidate.user)
  end

  test "proposal history is scoped paginated and counted independently of the visible page" do
    proposals = Array.new(12) do |index|
      assignment = create_assignment_for(@owner, title: "Own historical offer #{index}")
      proposal = create_proposal_for(assignment, @candidate)
      proposal.update_columns(created_at: index.minutes.ago)
      proposal
    end
    oldest = proposals.last
    oldest.assignment.update!(status: "cancelled")
    other = create_marketplace_account(prefix: "dashboard-history-other")
    other_assignment = create_assignment_for(@owner, title: "Another member private offer")
    create_proposal_for(other_assignment, other)

    get dashboard_path(locale: :en), params: { per_page: 100_000, user_id: other.user.id }

    assert_response :success
    assert_select ".proposal-preview", count: 10
    assert_select ".dashboard-summary .summary-card:nth-child(2) strong", text: "12"
    assert_select ".proposal-preview a[href='#{assignment_path(oldest.assignment, locale: :en)}']", count: 0
    assert_select "a[href='#{dashboard_path(locale: :en, proposal_page: 2, anchor: 'proposal-history')}'][rel='next']"
    assert_not_includes response.body, other_assignment.title

    get dashboard_path(locale: :en), params: { proposal_page: 2 }

    assert_response :success
    assert_select ".proposal-preview", count: 2
    assert_select ".dashboard-summary .summary-card:nth-child(2) strong", text: "12"
    assert_select ".proposal-preview a[href='#{assignment_path(oldest.assignment, locale: :en)}']"
    assert_select "a[href='#{dashboard_path(locale: :en, proposal_page: 1, anchor: 'proposal-history')}'][rel='prev']"
    assert_select ".proposal-preview p", text: /Cancelled/
    assert_equal "pending", oldest.reload.status

    get dashboard_path(locale: :en), params: { proposal_page: -20 }
    assert_select ".proposal-preview", count: 10
    get dashboard_path(locale: :en), params: { proposal_page: 100_000 }
    assert_select ".proposal-preview", count: 2
    get dashboard_path(locale: :en), params: { proposal_page: [ "2" ] }
    assert_response :success
    assert_select ".proposal-preview", count: 10
  end

  test "pagination preserves the selected language" do
    11.times do |index|
      create_proposal_for(create_assignment_for(@owner, title: "Localized offer #{index}"), @candidate)
    end

    %i[nl fr de en].each do |locale|
      get dashboard_path(locale:), params: { proposal_page: 2 }

      assert_response :success
      assert_select "#proposal-history nav[aria-label='#{I18n.t('workflow.ui.your_proposals', locale:)}']"
      assert_select "#proposal-history nav span", text: I18n.t("notification_center.page", locale:, current: 2, total: 2)
      assert_select "a[href='#{dashboard_path(locale:, proposal_page: 1, anchor: 'proposal-history')}']", text: I18n.t("notification_center.previous", locale:)
      assert_no_match(/translation missing/i, response.body)
    end
  end

  test "dashboard offers identify hourly fixed and separate travel prices in every language" do
    hourly_assignment = create_assignment_for(@owner, title: "Hourly offer with kilometre travel")
    hourly = create_proposal_for(hourly_assignment, @candidate, rate_cents: 9_000)
    hourly.update!(rate_kind: "hourly", travel_included: false, travel_cost_kind: "per_km", travel_cost_cents: 45)
    fixed_assignment = create_assignment_for(@owner, title: "Fixed offer including travel")
    fixed = create_proposal_for(fixed_assignment, @candidate, rate_cents: 18_000)
    fixed.update!(rate_kind: "fixed", travel_included: true)

    %i[nl fr de en].each do |locale|
      get dashboard_path(locale:)

      assert_response :success
      assert_select ".proposal-preview", text: /#{Regexp.escape(hourly_assignment.title)}.*#{Regexp.escape(I18n.t('marketplace.rate_kinds.hourly', locale:))}/m do
        assert_select ".proposal-travel-summary", text: I18n.t("proposal_travel.additional_per_km", locale:, amount: locale == :en ? "0.45" : "0,45")
      end
      assert_select ".proposal-preview", text: /#{Regexp.escape(fixed_assignment.title)}.*#{Regexp.escape(I18n.t('marketplace.rate_kinds.fixed', locale:))}/m do
        assert_select ".proposal-travel-summary", text: I18n.t("proposal_travel.included", locale:)
      end
    end
  end

  test "both parties see terminal assignment status without rewriting pending proposal history" do
    assignment = create_assignment_for(@owner)
    proposal = create_proposal_for(assignment, @candidate)

    %w[cancelled expired completed].each do |status|
      assignment.update!(status:)
      [ @candidate.user, @owner.user ].each do |user|
        sign_in_as(user)
        assert_no_difference [ "AuditEvent.count", "Notification.count" ] do
          get assignment_path(assignment, locale: :en)
        end

        assert_response :success
        assert_select ".candidate-proposal__header .status-pill", text: I18n.t("marketplace.status.#{status}", locale: :en)
        assert_select "form[action='#{withdraw_assignment_proposal_path(assignment, proposal, locale: :en)}']", count: 0
        assert_equal "pending", proposal.reload.status
      end
    end
  end

  test "decided proposal status remains distinct from assignment closure" do
    assignment = create_assignment_for(@owner)
    proposal = create_proposal_for(assignment, @candidate)
    assignment.update!(status: "cancelled")

    %w[accepted declined withdrawn].each do |status|
      proposal.update!(status:)
      get assignment_path(assignment, locale: :en)

      assert_response :success
      assert_select ".candidate-proposal__header .status-pill", text: I18n.t("marketplace.status.#{status}", locale: :en)
      assert_equal status, proposal.reload.status
    end
  end

  test "an offer can be withdrawn after the response deadline while it can still be accepted" do
    assignment = create_assignment_for(@owner)
    proposal = create_proposal_for(assignment, @candidate)
    get assignment_path(assignment, locale: :en)
    assert_select "form[action='#{withdraw_assignment_proposal_path(assignment, proposal, locale: :en)}']", count: 1

    assignment.update!(response_deadline_at: 1.minute.ago)
    get assignment_path(assignment, locale: :en)
    assert_select "form[action='#{withdraw_assignment_proposal_path(assignment, proposal, locale: :en)}']", count: 1
    assignment.update!(starts_at: 1.minute.ago, response_deadline_at: 2.minutes.ago)
    get assignment_path(assignment, locale: :en)
    assert_select "form[action='#{withdraw_assignment_proposal_path(assignment, proposal, locale: :en)}']", count: 0
    assert_equal "pending", proposal.reload.status
  end

  test "owned and suggested dashboard courts use the selected interface language" do
    @candidate.profile.update!(practice_areas: [ "Commercial law" ])
    own = create_assignment_for(@candidate, title: "Owned Aalst court")
    suggested = create_assignment_for(@owner, title: "Suggested Aalst court")
    [ own, suggested ].each { |assignment| assignment.update!(court: "Vredegerecht Aalst 1", city: "Aalst") }

    %i[nl fr de en].each do |locale|
      get dashboard_path(locale:)

      assert_response :success
      expected = CourtHearingLocations.find(name: own.court, city: own.city, locale:).court_name
      [ own, suggested ].each do |assignment|
        assert_select "a.compact-row[href='#{assignment_path(assignment, locale:)}'] .compact-row__copy small", text: expected
      end
    end
  end
end
