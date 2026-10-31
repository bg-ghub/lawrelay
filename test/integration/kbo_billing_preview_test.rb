require "test_helper"

class KboBillingPreviewTest < ActionDispatch::IntegrationTest
  test "retired company lookup cannot collect an enterprise number in any locale" do
    %i[nl fr de en].each do |locale|
      post "/#{locale}/company-lookup", params: { enterprise_number: "1234567894" }

      assert_response :not_found
    end
  end
end
