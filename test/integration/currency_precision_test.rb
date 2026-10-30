require "test_helper"
require_relative "../support/marketplace_test_factory"

class CurrencyPrecisionTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "assignments can be posted with an omitted or blank indicative fee in every language" do
    owner = create_marketplace_account(prefix: "optionalfeeowner")
    sign_in_as(owner.user)

    %w[nl fr de en].each_with_index do |locale, index|
      get new_assignment_path(locale:)
      assert_response :success
      assert_select "input[name='assignment[fee_cents]']:not([required])", count: 1

      attributes = {
        kind: "court_replacement", title: "Optional fee #{locale}", description: "A bounded assignment without client information.",
        city: "Brussels", court: "Enterprise Court", starts_at: 3.days.from_now,
        duration_minutes: 60, practice_area: "Commercial law", content_rules_accepted: "1"
      }.merge(invoice_recipient_attributes)
      attributes[:fee_cents] = [ nil, "", " ", nil ][index] unless index.zero?
      assert_difference("Assignment.count", 1) do
        post assignments_path(locale:), params: { assignment: attributes }
      end
      assignment = Assignment.order(:id).last
      assert_redirected_to assignment_path(assignment, locale:)
      assert_nil assignment.fee_cents
    end
  end

  test "unspecified fees are localized and remain distinct from an explicit zero fee" do
    owner = create_marketplace_account(prefix: "unspecifiedfeeowner")
    candidate = create_marketplace_account(prefix: "unspecifiedfeecandidate")
    assignment = create_assignment_for(owner)
    assignment.update!(fee_cents: nil)
    sign_in_as(candidate.user)

    { nl: "In overleg", fr: "À convenir", de: "Nach Vereinbarung", en: "To be agreed" }.each do |locale, label|
      get assignment_path(assignment, locale:)
      assert_response :success
      assert_select ".proposal-panel__price strong", text: label
      assert_select "input[name='proposal[rate_cents]'][required]:not([value])", count: 1
      get assignments_path(locale:)
      assert_response :success
      assert_select ".rate-note strong", text: label
    end

    assignment.update!(fee_cents: 0)
    get assignment_path(assignment, locale: :en)
    assert_select ".proposal-panel__price strong", text: "€ 0"
    assert_select "input[name='proposal[rate_cents]'][required][value='0']", count: 1
  end

  test "fractional euros survive proposal validation and render in each locale" do
    owner = create_marketplace_account(prefix: "decimalowner")
    candidate = create_marketplace_account(prefix: "decimalcandidate")
    assignment = create_assignment_for(owner)
    assignment.update!(fee_cents: 25_055)
    sign_in_as(candidate.user)

    %w[nl fr de en].each do |locale|
      get assignment_path(assignment, locale:)
      assert_response :success
      assert_select ".proposal-panel__price strong", text: locale == "en" ? "€ 250.55" : "€ 250,55"
      assert_select "input[name='proposal[rate_cents]'][value='250.55'][step='0.01']"

      post assignment_proposals_path(assignment, locale:), params: {
        proposal: { rate_cents: "275.65", message: "" }
      }
      assert_response :unprocessable_content
      assert_select "input[name='proposal[rate_cents]'][value='275.65']"
    end

    proposal = create_proposal_for(assignment, candidate, rate_cents: 27_565)
    get dashboard_path(locale: :en)
    assert_select ".proposal-preview p", text: /275\.65/
    sign_in_as(owner.user)
    get assignment_path(assignment, locale: :nl)
    assert_select ".candidate-proposal strong", text: "€ 275,65"
    assert_equal 27_565, proposal.reload.rate_cents
  end

  test "an assignment form preserves cents and zero after another field fails validation" do
    owner = create_marketplace_account(prefix: "decimalposting")
    sign_in_as(owner.user)

    %w[250.55 0].each do |amount|
      assert_no_difference "Assignment.count" do
        post assignments_path(locale: :nl), params: {
          assignment: {
            title: "", kind: "court_replacement", fee_cents: amount,
            starts_at: 3.days.from_now, response_deadline_at: 2.days.from_now,
            content_rules_accepted: "1"
          }
        }
      end
      assert_response :unprocessable_content
      assert_select "input[name='assignment[fee_cents]'][value='#{amount}'][step='0.01']"
    end
  end
end
