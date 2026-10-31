require "test_helper"
require_relative "../../support/marketplace_test_factory"

class PrivacyCompanyDataCleanupTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "retired-company")
    @account.firm.update_columns(name: "Retired company", enterprise_number: "0123456789",
      vat_number: "BE0123456789", billing_email: "old-billing@example.test", phone: "old-phone",
      address_line_1: "Old office 1", postal_code: "1000", city: "Brussels",
      kbo_details: { "snapshot_date" => "2026-10-30", "fields" => [ "name" ] })
    @assignment = create_assignment_for(@account)
    @assignment.update_columns(status: "completed", starts_at: 1.day.ago, closed_at: Time.current,
      invoice_name: "Old recipient", invoice_enterprise_number: "0123456789", invoice_email: "old-recipient@example.test",
      invoice_address_line_1: "Old recipient 1", invoice_postal_code: "1000", invoice_city: "Brussels",
      invoice_kbo_details: { "snapshot_date" => "2026-10-30", "fields" => [ "name" ] })
  end

  test "dry run reports without changing company or account records" do
    originals = [ @account.firm.attributes, @assignment.attributes, @account.user.attributes ]
    result = Privacy::CompanyDataCleanup.new.call

    assert_equal 1, result.firms
    assert_equal 1, result.assignments
    assert_equal originals, [ @account.firm.reload.attributes, @assignment.reload.attributes, @account.user.reload.attributes ]
  end

  test "removes retired data idempotently without changing identity permissions or work" do
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes
    membership = @account.user.primary_membership.attributes
    firm_status = @account.firm.attributes.slice("id", "verification_status", "verified_at")
    assignment_state = @assignment.attributes.slice("id", "firm_id", "creator_user_id", "title", "status")

    result = Privacy::CompanyDataCleanup.new(dry_run: false).call
    assert_equal 1, result.firms
    assert_equal 1, result.assignments
    assert_equal 0, result.protected_records
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, @account.firm.reload.name
    Privacy::CompanyDataCleanup::FIRM_FIELDS.each { |field| assert_nil @account.firm.public_send(field) }
    assert_equal({}, @account.firm.kbo_details)
    Privacy::CompanyDataCleanup::ASSIGNMENT_FIELDS.each { |field| assert_nil @assignment.reload.public_send(field) }
    assert_equal({}, @assignment.invoice_kbo_details)
    assert_equal original_user, @account.user.reload.attributes
    assert_equal original_profile, @account.profile.reload.attributes
    assert_equal membership, @account.user.primary_membership.attributes
    assert_equal firm_status, @account.firm.attributes.slice(*firm_status.keys)
    assert_equal assignment_state, @assignment.attributes.slice(*assignment_state.keys)
    again = Privacy::CompanyDataCleanup.new(dry_run: false).call
    assert_equal 0, again.firms
    assert_equal 0, again.assignments
  end

  test "clears unused billing contact metadata without deleting the internal account" do
    account = BillingAccount.create!(firm: @account.firm, billing_email: "old-account@example.test",
      peppol_id: "old-peppol", provider_customer_id: "old-customer")
    result = Privacy::CompanyDataCleanup.new(dry_run: false).call

    assert_equal 1, result.billing_accounts
    assert BillingAccount.exists?(account.id)
    Privacy::CompanyDataCleanup::BILLING_FIELDS.each { |field| assert_nil account.reload.public_send(field) }
  end

  test "preserves financial evidence and its linked company details for review" do
    account = BillingAccount.create!(firm: @account.firm, billing_email: "protected@example.test")
    invoice = Invoice.create!(billing_account: account, status: "issued", subtotal_cents: 1_000,
      vat_rate_basis_points: 2100, issued_on: Date.current)
    originals = [ @account.firm.attributes, @assignment.attributes, account.attributes, invoice.attributes ]

    result = Privacy::CompanyDataCleanup.new(dry_run: false).call
    assert_equal 3, result.protected_records
    assert_equal originals, [ @account.firm.reload.attributes, @assignment.reload.attributes, account.reload.attributes, invoice.reload.attributes ]
  end

  test "preserves held details and removes them when the hold has expired" do
    operator = users(:one)
    operator.update!(system_role: "admin", admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    hold = RetentionHold.create!(subject: @account.firm, actor: operator, reason: "Synthetic dispute", expires_at: 1.day.from_now)
    result = Privacy::CompanyDataCleanup.new(dry_run: false).call
    assert_equal 2, result.protected_records
    assert_equal "Retired company", @account.firm.reload.name

    hold.update_columns(expires_at: 1.day.ago)
    Privacy::CompanyDataCleanup.new(dry_run: false).call
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, @account.firm.reload.name
    assert_nil @assignment.reload.invoice_name
  end
end
