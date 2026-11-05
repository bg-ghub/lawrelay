require "test_helper"
require_relative "../support/marketplace_test_factory"

class AssignmentEmptyStateTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  EMPTY_TITLES = {
    nl: "Nog geen openstaande opdrachten",
    fr: "Aucune mission ouverte pour le moment",
    de: "Derzeit keine offenen Aufträge",
    en: "No open assignments yet"
  }.freeze

  setup do
    @account = create_marketplace_account(prefix: "empty-board")
    sign_in_as(@account.user)
  end

  test "an unfiltered empty board invites posting instead of changing filters in every language" do
    EMPTY_TITLES.each_key do |locale|
      get assignments_path(locale:)

      assert_response :success
      assert_empty_board(locale)
    end
  end

  test "effective filter misses retain guidance and a reset action in every language" do
    create_assignment_for(@account)
    filters = [ { q: "Unmatched query" }, { city: "Unmatched city" }, { practice_area: "Unmatched area" }, { kind: "legal_task" } ]

    EMPTY_TITLES.each_key do |locale|
      filters.each do |params|
        get assignments_path(locale:), params: params

        assert_response :success
        assert_filtered_empty(locale)
      end
    end
  end

  test "blank and ignored query values do not count as active filters" do
    ignored = [
      { q: "", city: "", practice_area: "", kind: "" },
      { q: " \t ", city: " \n ", practice_area: "  ", kind: " " },
      { kind: "invalid-kind" }
    ]

    EMPTY_TITLES.each_key do |locale|
      ignored.each do |params|
        get assignments_path(locale:), params: params

        assert_response :success
        assert_empty_board(locale)
      end
    end

    assignment = create_assignment_for(@account)
    EMPTY_TITLES.each_key do |locale|
      ignored.each do |params|
        get assignments_path(locale:), params: params

        assert_response :success
        assert_select ".assignment-card h2", text: assignment.title
        assert_select ".empty-state", count: 0
      end
    end
  end

  test "Turbo frame responses choose the same empty state on the server in every language" do
    EMPTY_TITLES.each_key do |locale|
      [ {}, { q: "Unmatched query" } ].each do |params|
        get assignments_path(locale:), params: params, headers: { "Turbo-Frame" => "assignment-results" }

        assert_response :success
        assert_select "turbo-frame#assignment-results", count: 1
        assert_select ".site-header", count: 0
        params.empty? ? assert_empty_board(locale) : assert_filtered_empty(locale)
      end
    end
  end

  private

  def assert_empty_board(locale)
    assert_select "#assignment-results .empty-state" do
      assert_select "h2", text: EMPTY_TITLES.fetch(locale)
      assert_select "p", count: 0
      assert_select "a[href='#{new_assignment_path(locale:)}']", text: I18n.t("marketplace.index.post_assignment", locale:)
      assert_select "a[href='#{assignments_path(locale:)}']", count: 0
    end
  end

  def assert_filtered_empty(locale)
    assert_select "#assignment-results .empty-state" do
      assert_select "h2", text: I18n.t("marketplace.index.empty_title", locale:)
      assert_select "p", text: I18n.t("marketplace.index.empty_body", locale:)
      assert_select "a[href='#{assignments_path(locale:)}']", text: I18n.t("marketplace.index.all_assignments", locale:)
      assert_select "a[href='#{new_assignment_path(locale:)}']", count: 0
    end
  end
end
