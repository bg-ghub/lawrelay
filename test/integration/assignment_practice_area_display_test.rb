require "test_helper"
require_relative "../support/marketplace_test_factory"

class AssignmentPracticeAreaDisplayTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @owner = create_marketplace_account(prefix: "practiceareadisplay")
    @assignment = create_assignment_for(@owner, title: "Synthetic civil assignment")
    sign_in_as(@owner.user)
  end

  test "cards and details translate known practice areas stored in another language" do
    %i[nl fr de en].each do |source_locale|
      stored_area = I18n.t("marketplace.practice_areas.civil", locale: source_locale)
      @assignment.update!(practice_area: stored_area)

      %i[nl fr de en].each do |locale|
        label = I18n.t("marketplace.practice_areas.civil", locale:)
        get assignments_path(locale:)
        assert_response :success
        assert_select ".assignment-card .assignment-facts dd", text: label
        get assignment_path(@assignment, locale:)
        assert_response :success
        assert_select ".detail-facts dd", text: label
      end
      assert_equal stored_area, @assignment.reload.practice_area
    end
  end

  test "custom practice areas retain their entered wording" do
    custom_area = "Maritime mediation (custom)"
    @assignment.update!(practice_area: custom_area)

    %i[nl fr de en].each do |locale|
      get assignments_path(locale:)
      assert_response :success
      assert_select ".assignment-card .assignment-facts dd", text: custom_area
      assert_select "select#practice_area option[value='#{custom_area}']", text: custom_area
      get assignment_path(@assignment, locale:)
      assert_response :success
      assert_select ".detail-facts dd", text: custom_area
    end
  end

  test "translated filter labels keep the stored value and select the matching assignments" do
    stored_area = I18n.t("marketplace.practice_areas.civil", locale: :en)
    @assignment.update!(practice_area: stored_area)
    other_assignment = create_assignment_for(@owner, title: "Synthetic family assignment")
    other_assignment.update!(practice_area: I18n.t("marketplace.practice_areas.family", locale: :fr))

    %i[nl fr de en].each do |locale|
      get assignments_path(locale:), params: { practice_area: stored_area }
      assert_response :success
      assert_select "select#practice_area option[value='#{stored_area}'][selected]", text: I18n.t("marketplace.practice_areas.civil", locale:)
      assert_select ".assignment-card", count: 1
      assert_select ".assignment-card h2", text: @assignment.title
      assert_select ".assignment-card h2", text: other_assignment.title, count: 0
    end
    assert_equal stored_area, @assignment.reload.practice_area
  end

  test "one standard filter finds all stored language variants without duplicate choices" do
    english_area = I18n.t("marketplace.practice_areas.civil", locale: :en)
    dutch_area = I18n.t("marketplace.practice_areas.civil", locale: :nl)
    @assignment.update!(practice_area: english_area)
    dutch_assignment = create_assignment_for(@owner, title: "Synthetic Dutch civil assignment")
    dutch_assignment.update!(practice_area: dutch_area)
    custom_assignment = create_assignment_for(@owner, title: "Synthetic custom assignment")
    custom_assignment.update!(practice_area: "Civil law specialist")

    %i[nl fr de en].each do |locale|
      get assignments_path(locale:)
      label = I18n.t("marketplace.practice_areas.civil", locale:)
      assert_select "select#practice_area option", text: label, count: 1

      [ english_area, dutch_area, label ].uniq.each do |filter_value|
        get assignments_path(locale:), params: { practice_area: filter_value }
        assert_response :success
        assert_select "select#practice_area option[selected]", text: label, count: 1
        assert_select ".assignment-card", count: 2
        assert_select ".assignment-card h2", text: @assignment.title
        assert_select ".assignment-card h2", text: dutch_assignment.title
        assert_select ".assignment-card h2", text: custom_assignment.title, count: 0
      end
      get assignments_path(locale:), params: { practice_area: custom_assignment.practice_area }
      assert_select ".assignment-card", count: 1
      assert_select ".assignment-card h2", text: custom_assignment.title
    end
    assert_equal english_area, @assignment.reload.practice_area
    assert_equal dutch_area, dutch_assignment.reload.practice_area
  end

  test "candidate and settings tags localize standard areas but preserve imported custom wording" do
    candidate = create_marketplace_account(prefix: "practiceareacandidate")
    profile_id = SecureRandom.uuid
    stored_areas = [ I18n.t("marketplace.practice_areas.family", locale: :en), "Custom maritime practice" ]
    candidate.profile.update!(directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: candidate.user.full_name, directory_email: candidate.user.email_address,
      directory_checked_at: Time.current, practice_areas: stored_areas)
    create_proposal_for(@assignment, candidate)

    %i[nl fr de en].each do |locale|
      get assignment_path(@assignment, locale:)
      assert_response :success
      assert_select ".candidate-location .directory-profile__tag", text: I18n.t("marketplace.practice_areas.family", locale:)
      assert_select ".candidate-location .directory-profile__tag", text: "Custom maritime practice"
    end

    sign_in_as(candidate.user)
    %i[nl fr de en].each do |locale|
      get settings_path(locale:)
      assert_response :success
      assert_select ".directory-profile__data .directory-profile__tag", text: I18n.t("marketplace.practice_areas.family", locale:)
      assert_select ".directory-profile__data .directory-profile__tag", text: "Custom maritime practice"
    end
    assert_equal stored_areas, candidate.profile.reload.practice_areas
  end

  test "homepage opportunities localize standard areas and preserve custom wording" do
    stored_area = I18n.t("marketplace.practice_areas.civil", locale: :en)
    @assignment.update!(practice_area: stored_area)
    custom_assignment = create_assignment_for(@owner, title: "Synthetic custom opportunity")
    custom_assignment.update!(practice_area: "Custom maritime practice")

    %i[nl fr de en].each do |locale|
      get root_path(locale:)
      assert_response :success
      assert_select ".opportunity-bottom > span", text: I18n.t("marketplace.practice_areas.civil", locale:)
      assert_select ".opportunity-bottom > span", text: "Custom maritime practice"
    end
    assert_equal stored_area, @assignment.reload.practice_area
  end
end
