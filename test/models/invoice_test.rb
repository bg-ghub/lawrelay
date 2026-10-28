require "test_helper"

class InvoiceTest < ActiveSupport::TestCase
  def billing_account
    user = User.create!(email_address: "billing-#{SecureRandom.uuid}@example.test", password: "password123", password_confirmation: "password123", first_name: "Billing", last_name: "Owner")
    firm = Firm.create!(name: "Billing Firm #{SecureRandom.uuid}")
    Membership.create!(user:, firm:, role: "owner")
    BillingAccount.create!(firm:)
  end

  test "calculates VAT-inclusive totals" do
    invoice = billing_account.invoices.create!(subtotal_cents: 4900, vat_rate_basis_points: 2100)

    assert_equal 1029, invoice.vat_cents
    assert_equal 5929, invoice.total_cents
  end

  test "issues a sequential LawRelay invoice number" do
    invoice = billing_account.invoices.create!(subtotal_cents: 4900)

    invoice.issue!

    assert_match(/\ALR-#{Date.current.year}-\d{5}\z/, invoice.number)
    assert_equal "issued", invoice.status
    assert_equal "not_requested", invoice.peppol_status
  end
end
