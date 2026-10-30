require "test_helper"
require_relative "../support/marketplace_test_factory"

class CompanyLookupsControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @original_call = BusinessRegistry::PublicLookup.method(:call)
    @result = BusinessRegistry::PublicLookup::Result.new(status: :ok,
      attributes: { name: "Test registry company", enterprise_number: "0781961243",
        address_line_1: "Test Street 10", postal_code: "1000", city: "Brussels" }, snapshot_date: Date.new(2026, 10, 29))
    calls = @calls = []
    result = @result
    BusinessRegistry::PublicLookup.define_singleton_method(:call) do |**arguments|
      calls << arguments
      result
    end
  end

  teardown do
    BusinessRegistry::PublicLookup.define_singleton_method(:call, @original_call)
  end

  test "anonymous signup lookup returns a signed preview and saves no records" do
    counts = -> { [ User.count, Firm.count, Assignment.count, AuditEvent.count ] }
    assert_no_changes counts do
      post company_lookup_path(locale: :fr), params: { enterprise_number: "0781.961.243" }, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal "Test registry company", body.dig("attributes", "name")
    assert_equal "2026-10-29", body["source_date"]
    assert_includes body["source_label"], "2026"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal [ { enterprise_number: "0781.961.243", locale: :fr } ], @calls
    record = Firm.new(body["attributes"])
    BusinessRegistry::Preview.apply(record, token: body["token"])
    assert_equal "2026-10-29", record.kbo_details["snapshot_date"]
    assert_not_includes response.body, "KBO_PASSWORD"
  end

  test "malformed lookup parameters never reach the service" do
    [ nil, [ "0781961243" ], { number: "0781961243" } ].each do |number|
      post company_lookup_path(locale: :en), params: { enterprise_number: number }, as: :json
      assert_response :unprocessable_content
      assert_equal "invalid", response.parsed_body["status"]
    end
    assert_empty @calls
  end

  test "a member lookup preserves its profile billing and verification" do
    account = create_marketplace_account(prefix: "kbolookup")
    sign_in_as(account.user)
    original = [ account.profile.attributes, account.firm.attributes ]
    post company_lookup_path(locale: :nl), params: { enterprise_number: "0781961243" }, as: :json
    assert_response :success
    assert_equal original, [ account.profile.reload.attributes, account.firm.reload.attributes ]
    assert_predicate account.user, :marketplace_verified?
  end

  test "a cross-site request without the signup CSRF token never reaches KBO" do
    previous = CompanyLookupsController.allow_forgery_protection
    CompanyLookupsController.allow_forgery_protection = true
    post company_lookup_path(locale: :en), params: { enterprise_number: "0781961243" },
      headers: { "Origin" => "https://unrelated.example" }, as: :json
    assert_response :unprocessable_content
    assert_empty @calls
  ensure
    CompanyLookupsController.allow_forgery_protection = previous
  end

  test "administrator accounts do not use marketplace lookup" do
    account = create_marketplace_account(prefix: "kboadmin", system_role: "admin")
    sign_in_as(account.user)
    post company_lookup_path(locale: :en), params: { enterprise_number: "0781961243" }, as: :json
    assert_response :forbidden
    assert_empty @calls
  end

  test "unavailable and not found messages are localized in every language" do
    %i[nl fr de en].each do |locale|
      %i[not_found unavailable not_configured invalid].each do |status|
        result = BusinessRegistry::PublicLookup::Result.new(status:, attributes: {}, snapshot_date: nil)
        BusinessRegistry::PublicLookup.define_singleton_method(:call) { |**| result }
        post company_lookup_path(locale:), params: { enterprise_number: "0781961243" }, as: :json
        assert_equal status.to_s, response.parsed_body["status"]
        assert_equal I18n.t("business_lookup.#{status}", locale:), response.parsed_body["message"]
        assert_response(status == :not_found ? :not_found : (status == :invalid ? :unprocessable_content : :service_unavailable))
      end
    end
  end
end
