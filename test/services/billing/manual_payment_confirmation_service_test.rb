require "test_helper"

class Billing::ManualPaymentConfirmationServiceTest < ActiveSupport::TestCase
  test "confirms one manual payment, activates one period, and records an audit event" do
    account = BillingAccount.create!(firm: Firm.create!(name: "Manual payment #{SecureRandom.uuid}"))
    result = Billing::ManualInvoiceService.new(billing_account: account).call
    operator = create_operator

    with_release_mode("paid") do
      travel_to Time.zone.parse("2026-10-28 10:00:00") do
        confirmation = service_for(result.payment, operator).call

        assert confirmation.activated
        assert_equal "paid", result.payment.reload.status
        assert_equal "paid", result.invoice.reload.status
        assert_equal "active", result.subscription.reload.status
        assert_equal 1.month.from_now, result.subscription.current_period_ends_at
        assert_equal "active", account.reload.status
        assert_equal 1, AuditEvent.where(auditable: result.payment, action: "billing.manual_payment_confirmed").count

        repeated = service_for(result.payment, operator).call
        assert_not repeated.activated
        assert_equal 1.month.from_now, result.subscription.reload.current_period_ends_at
        assert_equal 1, AuditEvent.where(auditable: result.payment, action: "billing.manual_payment_confirmed").count
      end
    end
  end

  test "does not reactivate a cancelled subscription" do
    account = BillingAccount.create!(firm: Firm.create!(name: "Cancelled manual #{SecureRandom.uuid}"))
    result = Billing::ManualInvoiceService.new(billing_account: account).call
    result.subscription.cancel!
    account.update!(status: "cancelled")

    with_release_mode("paid") do
      assert_raises(Billing::ManualPaymentConfirmationService::InvalidConfirmation) do
        service_for(result.payment, create_operator).call
      end
    end
  end

  test "does not confirm a manual payment during beta" do
    account = BillingAccount.create!(firm: Firm.create!(name: "Beta manual #{SecureRandom.uuid}"))
    result = Billing::ManualInvoiceService.new(billing_account: account).call

    assert_no_difference("AuditEvent.count") do
      assert_raises(Billing::ManualPaymentConfirmationService::PaymentsUnavailableDuringBeta) do
        service_for(result.payment, create_operator).call
      end
    end

    assert_equal "pending", result.payment.reload.status
    assert_equal "pending", result.subscription.reload.status
    assert_equal "pending", account.reload.status
  end

  private

  def service_for(payment, operator)
    Billing::ManualPaymentConfirmationService.new(
      payment:,
      actor_user: operator,
      payment_reference: "BANK-#{SecureRandom.hex(6)}"
    )
  end

  def create_operator
    User.create!(
      email_address: "billing-operator-#{SecureRandom.uuid}@example.test",
      password: "password1234",
      password_confirmation: "password1234",
      first_name: "Billing",
      last_name: "Operator",
      system_role: "admin"
    )
  end

  def with_release_mode(mode)
    original = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = mode
    yield
  ensure
    original.nil? ? ENV.delete("LAWRELAY_RELEASE_MODE") : ENV["LAWRELAY_RELEASE_MODE"] = original
  end
end
