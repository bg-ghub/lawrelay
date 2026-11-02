require "test_helper"
require_relative "../support/marketplace_test_factory"

class CourtAddressNotesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  test "Ciney floor notes localize on assignment cards and details while its street stays French" do
    owner = create_marketplace_account(prefix: "addressnotesowner")
    assignment = create_assignment_for(owner)
    entry = CourtCatalogue::DATA.fetch("courts").find { |court| court.fetch("source").end_with?("/justice-de-paix-de-ciney") }
    option = CourtCatalogue.option_for(entry, locale: :fr)
    assignment.update!(court: option.fetch(:label), city: option.fetch(:city))
    sign_in_as(owner.user)

    { nl: "3e verdieping", fr: "3e étage", de: "3. Stock", en: "3rd floor" }.each do |locale, floor|
      expected = "Rue Courtejoie 17 (#{floor}), 5590 Ciney"

      get assignment_path(assignment, locale:)
      assert_response :success
      assert_select ".detail-facts dd", text: expected

      get assignments_path(locale:)
      assert_response :success
      assert_select ".assignment-facts dd", text: expected
    end
  end
end
