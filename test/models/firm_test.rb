require "test_helper"

class FirmTest < ActiveSupport::TestCase
  test "beta posting access follows firm verification rather than billing" do
    firm = Firm.create!(name: "Beta firm", verification_status: "pending")

    refute firm.posting_access?
    firm.update!(verification_status: "verified", verified_at: Time.current)
    assert firm.posting_access?
  end

  test "paid mode retains billing gate" do
    firm = Firm.create!(name: "Paid firm", verification_status: "verified", verified_at: Time.current)

    with_env("LAWRELAY_RELEASE_MODE" => "paid", "LAWRELAY_BILLING_ENFORCED" => "true") do
      refute firm.posting_access?
    end
  end

  test "company details normalize a Belgian enterprise number and derive VAT" do
    firm = Firm.new(name: "Numbered company", enterprise_number: "BE 1234.567.894")

    assert firm.valid?(:company_details)
    assert_equal "1234567894", firm.enterprise_number
    assert_equal "BE1234567894", firm.vat_number
  end

  test "company details require a valid Belgian enterprise number without breaking legacy records" do
    legacy_firm = Firm.new(name: "Legacy company")
    invalid_firm = Firm.new(name: "Invalid company", enterprise_number: "1234567890")

    assert_predicate legacy_firm, :valid?
    refute legacy_firm.valid?(:company_details)
    refute invalid_firm.valid?(:company_details)
    assert_equal :invalid, invalid_firm.errors.details[:enterprise_number].first[:error]

    overlong_firm = Firm.new(name: "Overlong company", enterprise_number: "12345678941")
    refute overlong_firm.valid?(:company_details)
  end

  test "separate companies may use the same enterprise and derived VAT number" do
    first = Firm.new(name: "First independent company", enterprise_number: "1234567894")
    second = Firm.new(name: "Second independent company", enterprise_number: "1234567894")

    assert first.valid?(:company_details)
    assert second.valid?(:company_details)
    first.save!
    second.save!

    assert_equal first.enterprise_number, second.enterprise_number
    assert_equal first.vat_number, second.vat_number
    assert_not_equal first.id, second.id
  end

  private

  def with_env(values)
    old = values.to_h { |key, _| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
