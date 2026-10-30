require "test_helper"

class OperatorContactTest < ActionDispatch::IntegrationTest
  LOCALES = %i[nl fr de en].freeze
  COMPLAINT_URL = "https://www.gegevensbeschermingsautoriteit.be/burger/acties/klacht-indienen"

  setup do
    @operator_environment = PlatformOperator::ENVIRONMENT_FIELDS.values.to_h { |key| [ key, ENV[key] ] }
  end

  teardown do
    @operator_environment.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "privacy terms and legal notice show contact details without professional credentials" do
    operator = PlatformOperator.details

    LOCALES.each do |locale|
      [ privacy_path(locale:), terms_path(locale:) ].each do |path|
        get path

        assert_response :success
        assert_select ".operator-contact", count: 1
        assert_select ".operator-contact dt", count: PlatformOperator::ENVIRONMENT_FIELDS.size - 1
        %i[legal_name registered_address enterprise_number vat_number].each do |field|
          assert_includes response.body, operator.fetch(field)
        end
        %i[legal_email privacy_email support_email].each do |field|
          assert_select ".operator-contact a[href='mailto:#{operator.fetch(field)}']", text: operator.fetch(field)
        end
        assert_select ".operator-contact a[href='tel:+32474780957']", text: operator.fetch(:phone)
        assert_select ".operator-contact > p:first-of-type", text: operator.fetch(:legal_name)
        assert_no_professional_credentials
        assert_select ".operator-contact a[href='#{legal_notice_path(locale:)}']"
      end

      get privacy_path(locale:)
      assert_select ".operator-contact a[href='#{COMPLAINT_URL}']"

      get terms_path(locale:)
      assert_select ".operator-contact a[href='#{COMPLAINT_URL}']", count: 0

      get legal_notice_path(locale:)
      assert_response :success
      assert_select ".detail-facts dt", count: PlatformOperator::ENVIRONMENT_FIELDS.size
      assert_includes response.body, operator.fetch(:legal_name)
      assert_no_professional_credentials
    end
  end

  test "operator contact uses environment overrides and is absent from cookies" do
    ENV["LAWRELAY_LEGAL_NAME"] = "Configured operator"
    ENV["LAWRELAY_PHONE"] = "+32 470 00 00 00"

    get privacy_path(locale: :en)

    assert_response :success
    assert_select ".operator-contact", text: /Configured operator/
    assert_select ".operator-contact a[href='tel:+32470000000']", text: "+32 470 00 00 00"
    assert_not_includes response.body, "Gauthier Berth"

    get terms_path(locale: :en)
    assert_response :success
    assert_select ".operator-contact", text: /Configured operator/
    assert_not_includes response.body, "Gauthier Berth"

    get cookies_path(locale: :en)
    assert_response :success
    assert_select ".operator-contact", count: 0
  end

  private

  def assert_no_professional_credentials
    assert_not_includes response.body, "Balie Brussel (Nederlandse Orde)"
    assert_select "a[href*='advocaat.be/']", count: 0
    assert_select "a[href*='ordevanvlaamsebalies.be/']", count: 0
  end
end
