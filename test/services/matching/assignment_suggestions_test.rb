require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Matching::AssignmentSuggestionsTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  test "ranks open assignments by court, practice area and legal-task language" do
    candidate = create_marketplace_account(prefix: "suggestioncandidate")
    candidate.profile.update!(
      practice_areas: [ "Commercial law" ],
      court_preferences: [ "Enterprise Court Brussels" ],
      spoken_languages: %w[NL FR]
    )
    court_owner = create_marketplace_account(prefix: "courtowner")
    legal_owner = create_marketplace_account(prefix: "legalowner")
    other_owner = create_marketplace_account(prefix: "otherowner")

    court_match = create_assignment_for(court_owner, title: "Court and practice match")
    legal_match = legal_owner.firm.assignments.create!(
      creator_user: legal_owner.user,
      kind: "legal_task",
      title: "Language and practice match",
      description: "A bounded assignment without client-identifying information.",
      city: "Brussels",
      starts_at: 2.days.from_now,
      duration_minutes: 60,
      practice_area: "Commercial law",
      languages: "FR",
      fee_cents: 250_00,
      content_rules_accepted_at: Time.current,
      status: "open"
    )
    unrelated = create_assignment_for(other_owner, title: "Unrelated assignment")
    unrelated.update!(court: "Criminal Court", city: "Liège", practice_area: "Criminal law")
    closed = create_assignment_for(other_owner, title: "Closed match", status: "completed")

    suggestions = Matching::AssignmentSuggestions.new(user: candidate.user).call

    assert_equal [ legal_match, court_match ], suggestions
    assert_not_includes suggestions, unrelated
    assert_not_includes suggestions, closed
  end

  test "never suggests a lawyer's own firm's open assignments" do
    candidate = create_marketplace_account(prefix: "ownfirmcandidate")
    candidate.profile.update!(practice_areas: [ "Commercial law" ], court_preferences: [ "Brussels" ])
    own = create_assignment_for(candidate, title: "Own assignment")

    suggestions = Matching::AssignmentSuggestions.new(user: candidate.user).call

    assert_not_includes suggestions, own
  end

  test "matches practice areas across supported interface languages" do
    candidate = create_marketplace_account(prefix: "languagecandidate")
    candidate.profile.update!(practice_areas: [ "Commercial law" ], court_preferences: [])
    owner = create_marketplace_account(prefix: "languageowner")
    assignment = create_assignment_for(owner, title: "Nederlandstalige match")
    assignment.update!(practice_area: "Handelsrecht")

    assert_includes Matching::AssignmentSuggestions.new(user: candidate.user).call, assignment
  end
end
