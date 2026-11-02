require "test_helper"
require_relative "../support/marketplace_test_factory"

class TravelEstimatesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @owner = create_marketplace_account(prefix: "travelviewowner")
    @candidate = create_marketplace_account(prefix: "travelviewcandidate")
    @peer = create_marketplace_account(prefix: "travelviewpeer")
    @candidate.profile.update!(directory_profile_id: SecureRandom.uuid,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @candidate.user.full_name, directory_email: @candidate.user.email_address,
      directory_checked_at: Time.current, directory_professional_address: "Example Street 13, 1000 Brussel",
      directory_bar_name: "Example Bar")
    @assignment = create_assignment_for(@owner)
    @proposal = create_proposal_for(@assignment, @candidate)
    @proposal.update!(rate_kind: "hourly")
  end

  test "only the assignment owner firm or proposal author can request the estimate" do
    colleague = create_marketplace_account(prefix: "travelviewcolleague")
    colleague.user.memberships.create!(firm: @owner.firm, role: "member")
    [ @owner.user, colleague.user, @candidate.user ].each do |user|
      sign_in_as(user)
      get assignment_proposal_travel_estimate_path(@assignment, @proposal, locale: :en), as: :json
      assert_response :success
      assert_equal "unavailable", response.parsed_body["status"]
      assert_equal "Route unavailable", response.parsed_body["text"]
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_not_includes response.body, "Example Street"
    end
    sign_in_as(@peer.user)
    get assignment_proposal_travel_estimate_path(@assignment, @proposal, locale: :en), as: :json
    assert_response :not_found
  end

  test "an unrelated proposal ID cannot be used under the managed assignment" do
    other_assignment = create_assignment_for(@peer)
    other_proposal = create_proposal_for(other_assignment, @candidate)
    sign_in_as(@owner.user)
    get assignment_proposal_travel_estimate_path(@assignment, other_proposal, locale: :en), as: :json
    assert_response :not_found
  end

  test "both fixed and hourly court estimates are localized" do
    sign_in_as(@owner.user)
    %w[fixed hourly].each do |rate_kind|
      @proposal.update!(rate_kind:)
      { nl: "Route niet beschikbaar", fr: "Itinéraire indisponible", de: "Route nicht verfügbar", en: "Route unavailable" }.each do |locale, text|
        get assignment_proposal_travel_estimate_path(@assignment, @proposal, locale:), as: :json
        assert_response :success
        assert_equal "unavailable", response.parsed_body["status"]
        assert_equal text, response.parsed_body["text"]
      end
    end
  end

  test "suspended candidates never get a route through a formerly valid proposal" do
    @candidate.user.update!(suspended_at: Time.current)
    sign_in_as(@owner.user)
    get assignment_proposal_travel_estimate_path(@assignment, @proposal, locale: :en), as: :json
    assert_response :success
    assert_equal "not_applicable", response.parsed_body["status"]
  end

  test "assignment owner sees directory bar address and travel for fixed offers" do
    @proposal.update!(rate_kind: "fixed")
    sign_in_as(@owner.user)
    get assignment_path(@assignment, locale: :en)
    assert_response :success
    assert_select ".candidate-location dd", text: "Example Bar"
    assert_select ".candidate-location dd", text: "Example Street 13, 1000 Brussel"
    assert_select ".candidate-travel", count: 1
  end

  test "hourly offers show a localized inline driving estimate instead of requiring a route click" do
    sign_in_as(@owner.user)
    ready = Travel::Estimate::Result.new(status: :ready, distance_meters: 38_000, duration_seconds: 2100)
    with_estimate(ready) do
      %i[nl fr de en].each do |locale|
        get assignment_path(@assignment, locale:)
        assert_response :success
        assert_select ".candidate-travel [data-travel-estimate-target='text']", text: /38 km.*35/
        assert_select ".candidate-travel[data-travel-estimate-pending-value='false']"
        assert_select ".candidate-travel a[href='https://www.openstreetmap.org/copyright']", text: "© OpenStreetMap"
        assert_select "iframe", count: 0
      end
    end
  end

  test "another lawyer viewing an open assignment cannot see a candidate's address or estimate URL" do
    sign_in_as(@peer.user)
    get assignment_path(@assignment, locale: :en)
    assert_response :success
    assert_select ".candidate-location", count: 0
    assert_select ".candidate-travel", count: 0
    assert_not_includes response.body, "Example Street 13"
    assert_not_includes response.body, assignment_proposal_travel_estimate_path(@assignment, @proposal, locale: :en)
  end

  test "proposal author sees their submitted hourly price and route without other bidders details" do
    @proposal.update!(rate_cents: 9_055)
    @peer.profile.update!(directory_profile_id: SecureRandom.uuid,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @peer.user.full_name, directory_email: @peer.user.email_address,
      directory_checked_at: Time.current, directory_professional_address: "Other Private Street 88, 9000 Gent",
      directory_bar_name: "Other Private Bar")
    other_proposal = create_proposal_for(@assignment, @peer, message: "Other bidder private offer", rate_cents: 12_345)
    other_proposal.update!(rate_kind: "hourly")
    sign_in_as(@candidate.user)
    ready = Travel::Estimate::Result.new(status: :ready, distance_meters: 38_000, duration_seconds: 2100)

    with_estimate(ready) do
      %i[nl fr de en].each do |locale|
        get assignment_path(@assignment, locale:)
        assert_response :success
        assert_select ".proposal-panel h2", text: I18n.t("workflow.ui.your_proposal", locale:)
        assert_select ".proposal-panel p strong", text: locale == :en ? "€ 90.55" : "€ 90,55"
        assert_select ".proposal-panel p", text: /#{Regexp.escape(I18n.t('marketplace.rate_kinds.hourly', locale:))}/
        assert_select ".candidate-travel", count: 1
        assert_select ".candidate-travel[data-travel-estimate-url-value='#{assignment_proposal_travel_estimate_path(@assignment, @proposal, locale:)}']"
        assert_select ".candidate-travel [data-travel-estimate-target='text']", text: /38 km.*35/
        assert_select ".candidate-travel a[href='https://www.openstreetmap.org/copyright']", text: "© OpenStreetMap"
        assert_select ".candidate-proposals .candidate-proposal", count: 0
        assert_select ".candidate-proposal--own", count: 1
        assert_not_includes response.body, "Other bidder private offer"
        assert_not_includes response.body, "Other Private Street 88"
        assert_not_includes response.body, "Other Private Bar"
        assert_not_includes response.body, @peer.user.full_name
        assert_not_includes response.body, assignment_proposal_travel_estimate_path(@assignment, other_proposal, locale:)
      end
    end
  end

  test "proposal author sees their fixed price and travel estimate" do
    @proposal.update!(rate_kind: "fixed", rate_cents: 12_345)
    sign_in_as(@candidate.user)

    %i[nl fr de en].each do |locale|
      get assignment_path(@assignment, locale:)
      assert_response :success
      assert_select ".proposal-panel p strong", text: locale == :en ? "€ 123.45" : "€ 123,45"
      assert_select ".proposal-panel p", text: /#{Regexp.escape(I18n.t('marketplace.rate_kinds.fixed', locale:))}/
      assert_select ".candidate-travel", count: 1
      assert_includes response.body, assignment_proposal_travel_estimate_path(@assignment, @proposal, locale:)
      assert_select ".candidate-location dd", text: "Example Street 13, 1000 Brussel"
    end
  end

  private

  def with_estimate(result)
    original = Travel::Estimate.method(:call)
    Travel::Estimate.define_singleton_method(:call) { |**| result }
    yield
  ensure
    Travel::Estimate.define_singleton_method(:call, original)
  end
end
