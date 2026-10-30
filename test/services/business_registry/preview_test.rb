require "test_helper"
require_relative "../../support/marketplace_test_factory"

class BusinessRegistryPreviewTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  def result
    BusinessRegistry::PublicLookup::Result.new(status: :ok, attributes: {
      name: "Test invoice company", enterprise_number: "0781961243", address_line_1: "Test Street 10",
      postal_code: "1000", city: "Brussels"
    }, snapshot_date: Date.new(2026, 10, 29))
  end

  def firm
    Firm.new(result.attributes)
  end

  test "only a signed matching preview attributes source fields" do
    record = firm
    BusinessRegistry::Preview.apply(record, token: BusinessRegistry::Preview.issue(result))
    assert_equal "2026-10-29", record.kbo_details["snapshot_date"]
    assert_equal BusinessRegistry::Preview::FIELDS.sort, record.kbo_details["fields"].sort
    assert_equal "pending", record.verification_status

    tampered = firm
    BusinessRegistry::Preview.apply(tampered, token: "forged-source-and-date")
    assert_equal({}, tampered.kbo_details)
  end

  test "changing the recipient number drops all attribution" do
    record = firm
    record.enterprise_number = "1234567894"
    BusinessRegistry::Preview.apply(record, token: BusinessRegistry::Preview.issue(result))
    assert_equal({}, record.kbo_details)
  end

  test "editing one imported value preserves the source of matching values only" do
    record = firm
    token = BusinessRegistry::Preview.issue(result)
    BusinessRegistry::Preview.apply(record, token:)
    record.save!
    record.name = "Manually corrected recipient"
    BusinessRegistry::Preview.apply(record)
    assert_not_includes record.kbo_details["fields"], "name"
    assert_includes record.kbo_details["fields"], "enterprise_number"
    assert_includes record.kbo_details["fields"], "address_line_1"
    assert_equal "2026-10-29", record.kbo_details["snapshot_date"]
  end

  test "missing registry address does not attribute manual address fields" do
    partial = BusinessRegistry::PublicLookup::Result.new(status: :ok,
      attributes: result.attributes.slice(:name, :enterprise_number), snapshot_date: result.snapshot_date)
    record = firm
    BusinessRegistry::Preview.apply(record, token: BusinessRegistry::Preview.issue(partial))
    assert_equal %w[enterprise_number name], record.kbo_details["fields"].sort
    assert_equal "Test Street 10", record.address_line_1
  end

  test "an expired preview cannot add registry attribution" do
    token = BusinessRegistry::Preview.issue(result)
    travel 2.hours do
      record = firm
      BusinessRegistry::Preview.apply(record, token:)
      assert_equal({}, record.kbo_details)
    end
  end

  test "assignment defaults copy only matching stored source fields" do
    account = create_marketplace_account(prefix: "kboattribution")
    account.firm.assign_attributes(result.attributes)
    BusinessRegistry::Preview.apply(account.firm, token: BusinessRegistry::Preview.issue(result))
    account.firm.save!

    assignment = Assignment.new(Assignment.default_invoice_recipient(firm: account.firm, user: account.user))
    BusinessRegistry::Preview.apply(assignment, fallback: account.firm)
    assert_equal account.firm.kbo_details, assignment.invoice_kbo_details
    assignment.invoice_enterprise_number = "1234567894"
    BusinessRegistry::Preview.apply(assignment, fallback: account.firm)
    assert_equal({}, assignment.invoice_kbo_details)
    assert_equal "0781961243", account.firm.enterprise_number
  end
end
