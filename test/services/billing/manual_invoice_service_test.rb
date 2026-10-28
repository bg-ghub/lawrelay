require "test_helper"

class Billing::ManualInvoiceServiceTest < ActiveSupport::TestCase
  test "creates a pending subscription, invoice and payment" do
    user = User.create!(email_address: "manual-#{SecureRandom.uuid}@example.test", password: "password1234", password_confirmation: "password1234", first_name: "Manual", last_name: "Owner")
    firm = Firm.create!(name: "Manual Firm #{SecureRandom.uuid}")
    Membership.create!(user:, firm:, role: "owner")
    account = BillingAccount.create!(firm:)

    result = Billing::ManualInvoiceService.new(billing_account: account).call

    assert_equal "pending", result.subscription.status
    assert_equal 4900, result.invoice.subtotal_cents
    assert_equal 5929, result.invoice.total_cents
    assert_equal "issued", result.invoice.status
    assert_equal "pending", result.payment.status
  end

  test "reuses a pending invoice request instead of duplicating it" do
    user = User.create!(email_address: "reuse-#{SecureRandom.uuid}@example.test", password: "password1234", password_confirmation: "password1234", first_name: "Reuse", last_name: "Owner")
    firm = Firm.create!(name: "Reuse Firm #{SecureRandom.uuid}")
    Membership.create!(user:, firm:, role: "owner")
    account = BillingAccount.create!(firm:)

    first = Billing::ManualInvoiceService.new(billing_account: account).call
    second = Billing::ManualInvoiceService.new(billing_account: account).call

    assert_equal first.subscription.id, second.subscription.id
    assert_equal first.invoice.id, second.invoice.id
    assert_equal first.payment.id, second.payment.id
  end

  test "repairs an existing pending subscription that has no invoice or payment" do
    firm = Firm.create!(name: "Repair Firm #{SecureRandom.uuid}")
    account = BillingAccount.create!(firm: firm)
    subscription = account.subscriptions.create!(
      provider: "manual", plan_key: "lawrelay_office", status: "pending", amount_cents: 4900
    )

    result = Billing::ManualInvoiceService.new(billing_account: account).call

    assert_equal subscription, result.subscription
    assert_predicate result.invoice, :persisted?
    assert_predicate result.payment, :persisted?
    assert_equal "lawrelay_office", account.reload.plan_key
  end
end
