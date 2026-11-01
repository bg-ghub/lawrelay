require "test_helper"
require_relative "../support/marketplace_test_factory"

class ProposalProfileDetailsTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "profile-owner")
    @candidate = create_marketplace_account(prefix: "profile-candidate")
    @peer = create_marketplace_account(prefix: "profile-peer")
    @candidate.profile.update!(bar_admission_year: 2014, court_preferences: [ "Gent", "Antwerpen" ],
      availability_note: "Tuesday mornings <script>private</script>")
    @assignment = create_assignment_for(@owner)
    @proposal = create_proposal_for(@assignment, @candidate)
  end

  test "owner sees admission year but no retired candidate preferences in all languages" do
    sign_in_as(@owner.user)
    %i[nl fr de en].each do |locale|
      get assignment_path(@assignment, locale:)
      assert_response :success
      assert_select ".candidate-profile dd", text: "2014"
      assert_select ".candidate-profile dd", count: 1
      assert_not_includes response.body, "Gent · Antwerpen"
      assert_not_includes response.body, "Tuesday mornings"
      assert_select ".candidate-profile__note", text: I18n.t("settings.preferences.self_reported", locale:)
      assert_select "script", text: "private", count: 0
    end
  end

  test "unrelated members cannot see another candidate's optional details" do
    sign_in_as(@peer.user)
    get assignment_path(@assignment, locale: :en)
    assert_response :success
    assert_select ".candidate-profile", count: 0
    assert_not_includes response.body, "Tuesday mornings"
  end

  test "an empty or suspended candidate profile has no optional context" do
    sign_in_as(@owner.user)
    @candidate.profile.update!(bar_admission_year: nil)
    get assignment_path(@assignment, locale: :en)
    assert_select ".candidate-profile", count: 0
    @candidate.profile.update!(bar_admission_year: 2014)
    @candidate.user.update!(suspended_at: Time.current)
    get assignment_path(@assignment, locale: :en)
    assert_select ".candidate-profile", count: 0
  end
end
