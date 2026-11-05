require "test_helper"
require_relative "../support/marketplace_test_factory"

class InputBoundariesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @account = create_marketplace_account(prefix: "input-boundaries")
    @assignment = create_assignment_for(@account, title: "Ordinary assignment")
    sign_in_as(@account.user)
  end

  test "structured assignment filters return a controlled bad request without changing records" do
    original_count = Assignment.count
    %i[q city practice_area kind].each do |filter|
      [ [ "synthetic" ], { "value" => "synthetic" } ].each do |value|
        get assignments_path(locale: :en), params: { filter => value }

        assert_response :bad_request
        assert_equal original_count, Assignment.count
        assert_equal "Ordinary assignment", @assignment.reload.title
      end
    end
  end

  test "SQL syntax and wildcard characters remain literal search values" do
    literal = create_assignment_for(@account, title: "Literal %_ ' OR 1=1 --")

    [ "' OR 1=1 --", "%_" ].each do |query|
      get assignments_path(locale: :en), params: { q: query }

      assert_response :success
      assert_select ".assignment-card", count: 1
      assert_select ".assignment-card h2", text: literal.title
      assert_select ".assignment-card h2", text: @assignment.title, count: 0
    end
  end

  test "stored assignment markup renders as text on cards and details" do
    title = '<img src=x onerror="alert(1)">'
    description = '<script>alert("synthetic")</script>'
    @assignment.update!(title:, description:)

    get assignments_path(locale: :en)
    assert_response :success
    assert_select ".assignment-card h2", text: title
    assert_select ".assignment-card img, .assignment-card script", count: 0
    assert_includes response.body, ERB::Util.html_escape(description)

    get assignment_path(@assignment, locale: :en)
    assert_response :success
    assert_select ".assignment-detail h1", text: title
    assert_select ".detail-intro", text: description
    assert_select ".detail-intro script, .assignment-detail h1 img", count: 0
  end

  test "unused upload routes are unavailable to anonymous requests" do
    delete session_path(locale: :en)

    post "/rails/active_storage/direct_uploads", params: {
      blob: { filename: "synthetic.txt", byte_size: 0, content_type: "text/plain",
              checksum: "1B2M2Y8AsgTpgAmY7PhCfg==" }
    }

    assert_response :not_found
  end
end
