require "test_helper"
require_relative "../support/marketplace_test_factory"

class AssignmentOtherChoicesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "a member can publish custom court and legal area details together" do
    account = create_marketplace_account(prefix: "custom-choices")
    sign_in_as(account.user)
    attributes = invoice_recipient_attributes.merge(kind: "court_replacement", assignment_subtype: "hearing",
      title: "Synthetic custom venue", description: "A bounded assignment without client information.",
      court: "Other", court_selection: Assignment::OTHER_CHOICE, court_other: "  Synthetic mediation office  ",
      city: "Brussels", practice_area: Assignment::OTHER_CHOICE, practice_area_other: "  Sports law  ",
      starts_at: 3.days.from_now, response_deadline_at: 2.days.from_now, duration_minutes: 60,
      content_rules_accepted: "1")

    assert_difference("Assignment.count", 1) do
      post assignments_path(locale: :en), params: { assignment: attributes }
    end
    assignment = account.firm.assignments.sole
    assert_redirected_to assignment_path(assignment, locale: :en)
    assert_equal "Synthetic mediation office", assignment.court
    assert_equal "Sports law", assignment.practice_area
    assert_equal "Brussels", assignment.city
    assert_equal account.user.id, assignment.creator_user_id
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Synthetic mediation office"
    assert_includes response.body, "Sports law"
    assert_not_includes response.body, Assignment::OTHER_CHOICE
  end
end
