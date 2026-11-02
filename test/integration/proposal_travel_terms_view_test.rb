require "test_helper"
require_relative "../support/marketplace_test_factory"

class ProposalTravelTermsViewTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []

  setup do
    @owner = create_marketplace_account(prefix: "traveltermsviewowner")
    @candidate = create_marketplace_account(prefix: "traveltermsviewcandidate")
    @candidate.profile.update!(directory_profile_id: SecureRandom.uuid,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @candidate.user.full_name, directory_email: @candidate.user.email_address,
      directory_checked_at: Time.current, directory_professional_address: "Example Street 13, 1000 Brussel",
      spoken_languages: %w[NL EN], practice_areas: [ "Synthetic civil practice" ])
    @assignment = create_assignment_for(@owner)
  end

  test "new court offers explicitly default to included travel with a hidden cost field" do
    sign_in_as(@candidate.user)

    %i[nl fr de en].each do |locale|
      get assignment_path(@assignment, locale:)
      assert_response :success
      assert_select ".proposal-travel-terms legend", text: I18n.t("proposal_travel.question", locale:)
      assert_select "input[name='proposal[travel_included]'][value='true'][checked]"
      assert_select "input[name='proposal[travel_included]'][value='false']:not([checked])"
      assert_select "[data-proposal-travel-target='cost'][hidden]"
      assert_select "input[name='proposal[travel_cost_kind]'][value='fixed'][checked][disabled]"
      assert_select "input[name='proposal[travel_cost_kind]'][value='per_km']:not([checked])[disabled]"
      assert_select "input[name='proposal[travel_cost_cents]'][disabled]:not([required])"
      assert_select "input[name='proposal[travel_cost_cents]'][value]", count: 0
      assert_select "input[name='proposal[travel_cost_cents]'][placeholder]", count: 0
      assert_no_match(/translation missing/i, response.body)
    end
  end

  test "both parties see travel terms and routes for fixed and hourly offers in every language" do
    proposal = create_proposal_for(@assignment, @candidate)
    ready = Travel::Estimate::Result.new(status: :ready, distance_meters: 38_000, duration_seconds: 2100)
    with_estimate(ready) do
      %w[fixed hourly].each do |rate_kind|
        [ [ true, nil ], [ false, "fixed" ], [ false, "per_km" ] ].each do |included, travel_cost_kind|
          amount_cents = travel_cost_kind == "per_km" ? 45 : 2_550
          proposal.update!(rate_kind:, travel_included: included, travel_cost_kind:, travel_cost_cents: included ? nil : amount_cents)
          [ @owner.user, @candidate.user ].each do |user|
            sign_in_as(user)
            %i[nl fr de en].each do |locale|
              get assignment_path(@assignment, locale:)
              assert_response :success
              expected = if included
                I18n.t("proposal_travel.included", locale:)
              elsif travel_cost_kind == "per_km"
                I18n.t("proposal_travel.additional_per_km", locale:, amount: locale == :en ? "0.45" : "0,45")
              else
                I18n.t("proposal_travel.additional", locale:, amount: locale == :en ? "25.50" : "25,50")
              end
              assert_select ".proposal-travel-summary", text: expected
              assert_select ".candidate-travel [data-travel-estimate-target='text']", text: /38 km.*35/
              assert_select ".candidate-travel a[href='https://www.openstreetmap.org/copyright']"
            end
          end
        end
      end
    end
  end

  test "legacy offers do not claim travel is included" do
    create_proposal_for(@assignment, @candidate)
    sign_in_as(@owner.user)
    get assignment_path(@assignment, locale: :en)
    assert_select ".proposal-travel-summary", text: "Travel costs not specified"
    assert_select ".candidate-travel", count: 1
  end

  test "the owner sees imported candidate context and an official link without preselection email disclosure" do
    create_proposal_for(@assignment, @candidate)
    sign_in_as(@owner.user)

    %i[nl fr de en].each do |locale|
      get assignment_path(@assignment, locale:)
      assert_response :success
      assert_select ".candidate-location .directory-profile__tag", text: I18n.t("profile_import.language_names.nl", locale:)
      assert_select ".candidate-location .directory-profile__tag", text: "Synthetic civil practice"
      assert_select ".candidate-location a[href='#{@candidate.profile.directory_profile_url}'][target='_blank'][rel='noopener noreferrer']", text: I18n.t("directory_location.profile_link", locale:)
      assert_not_includes response.body, @candidate.user.email_address
    end

    peer = create_marketplace_account(prefix: "traveltermsviewpeer")
    sign_in_as(peer.user)
    get assignment_path(@assignment, locale: :en)
    assert_select ".candidate-location", count: 0
    assert_not_includes response.body, "Synthetic civil practice"
    assert_not_includes response.body, @candidate.profile.directory_profile_url
  end

  test "an invalid stored official profile URL is never linked" do
    create_proposal_for(@assignment, @candidate)
    @candidate.profile.update_column(:directory_profile_url, "javascript:alert('synthetic')")
    sign_in_as(@owner.user)
    get assignment_path(@assignment, locale: :en)
    assert_response :success
    assert_select ".candidate-location a", count: 0
    assert_not_includes response.body, "javascript:alert"
  end

  test "legal tasks have no travel question price supplement or route" do
    @assignment.update!(kind: "legal_task", assignment_subtype: "advice", languages: "EN", court: nil, city: nil)
    sign_in_as(@candidate.user)
    get assignment_path(@assignment, locale: :en)
    assert_response :success
    assert_select ".proposal-travel-terms", count: 0
    create_proposal_for(@assignment, @candidate)
    [ @owner.user, @candidate.user ].each do |user|
      sign_in_as(user)
      get assignment_path(@assignment, locale: :en)
      assert_select ".proposal-travel-summary", count: 0
      assert_select ".candidate-travel", count: 0
    end
  end

  test "a failed proposal preserves the travel basis entered amount and matching label" do
    sign_in_as(@candidate.user)
    { "fixed" => [ "25.50", "25.5", "fixedLabel" ], "per_km" => [ "0.45", "0.45", "perKmLabel" ] }.each do |kind, (amount, field_value, label_target)|
      post assignment_proposals_path(@assignment, locale: :en), params: {
        proposal: { rate_kind: "fixed", rate_cents: "150", travel_included: "false", travel_cost_kind: kind, travel_cost_cents: amount, message: "" }
      }
      assert_response :unprocessable_content
      assert_select "input[name='proposal[travel_included]'][value='false'][checked]"
      assert_select "[data-proposal-travel-target='cost']:not([hidden])"
      assert_select "input[name='proposal[travel_cost_kind]'][value='#{kind}'][checked]:not([disabled])"
      assert_select "input[name='proposal[travel_cost_cents]'][value='#{field_value}'][required]:not([disabled])"
      assert_select "label[for='proposal_travel_cost_cents'] [data-proposal-travel-target='#{label_target}']:not([hidden])"
    end
  end

  test "a Dutch offer submission keeps its redirect and notice while English notification mail is delivered inline" do
    assert_equal "en", @candidate.user.locale
    assert_equal "en", @owner.user.locale
    sign_in_as(@candidate.user)

    perform_enqueued_jobs(only: NotificationEmailDeliveryJob) do
      post assignment_proposals_path(@assignment, locale: :nl), params: {
        proposal: { rate_kind: "fixed", rate_cents: "150", travel_included: "false", travel_cost_kind: "per_km", travel_cost_cents: "0,45", message: "A fictional offer with a separate kilometre rate." }
      }
    end

    assert_redirected_to assignment_path(@assignment, locale: :nl)
    assert_equal I18n.t("notices.proposal_created", locale: :nl), flash[:notice]
    assert_equal "sent", Notification.find_by!(user: @owner.user, kind: "new_proposal").email_status
    assert_equal "en", @candidate.user.reload.locale
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
