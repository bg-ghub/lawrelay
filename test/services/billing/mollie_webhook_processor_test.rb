require "test_helper"

class Billing::MollieWebhookProcessorTest < ActiveSupport::TestCase
  test "processes later lifecycle callbacks for the same payment exactly once per state" do
    firm = Firm.create!(name: "Webhook Firm #{SecureRandom.uuid}")
    account = BillingAccount.create!(firm: firm, provider: "mollie", plan_key: "lawrelay_office")
    subscription = account.subscriptions.create!(
      provider: "mollie",
      provider_subscription_id: "sub_#{SecureRandom.hex(4)}",
      plan_key: "lawrelay_office",
      status: "pending",
      amount_cents: 4900
    )
    payment = account.billing_payments.create!(
      subscription: subscription,
      provider: "mollie",
      provider_payment_id: "tr_#{SecureRandom.hex(4)}",
      status: "pending",
      amount_cents: 5929
    )

    process_with_provider_status(payment.provider_payment_id, "open")
    assert_equal "open", payment.reload.status

    process_with_provider_status(payment.provider_payment_id, "paid")
    assert_equal "paid", payment.reload.status
    assert_equal "active", subscription.reload.status
    first_period_end = subscription.current_period_ends_at

    process_with_provider_status(payment.provider_payment_id, "paid")
    assert_equal first_period_end, subscription.reload.current_period_ends_at
    assert_equal 1, WebhookEvent.where(provider: "mollie", external_id: payment.provider_payment_id).count
  end

  test "a late paid callback cannot reactivate a cancelled subscription" do
    account, subscription, payment = create_pending_payment
    subscription.cancel!
    account.update!(status: "cancelled")

    process_with_provider_status(payment.provider_payment_id, "paid")

    assert_equal "paid", payment.reload.status
    assert_equal "cancelled", subscription.reload.status
    assert_equal "cancelled", account.reload.status
  end

  test "a refund suspends access and is idempotent" do
    account, subscription, payment = create_pending_payment
    process_with_provider_status(payment.provider_payment_id, "paid")

    process_with_provider_status(payment.provider_payment_id, "refunded")
    assert_equal "refunded", payment.reload.status
    assert_equal "suspended", subscription.reload.status
    assert_equal "suspended", account.reload.status

    process_with_provider_status(payment.provider_payment_id, "refunded")
    assert_equal "refunded", payment.reload.status
    assert_equal "suspended", subscription.reload.status

    process_with_provider_status(payment.provider_payment_id, "paid")
    assert_equal "refunded", payment.reload.status
    assert_equal "suspended", subscription.reload.status
  end

  test "beta ignores Mollie callbacks without changing billing state" do
    account, subscription, payment = create_pending_payment
    gateway = Object.new
    gateway.define_singleton_method(:payment) { raise "Mollie must not be called during beta" }

    assert_no_difference("WebhookEvent.count") do
      assert_nil Billing::MollieWebhookProcessor.new(
        payment_id: payment.provider_payment_id,
        payload: { "id" => payment.provider_payment_id },
        gateway:
      ).call
    end

    assert_equal "pending", payment.reload.status
    assert_equal "pending", subscription.reload.status
    assert_equal "pending", account.reload.status
  end

  private

  def create_pending_payment
    firm = Firm.create!(name: "Webhook Firm #{SecureRandom.uuid}")
    account = BillingAccount.create!(firm: firm, provider: "mollie", plan_key: "lawrelay_office")
    subscription = account.subscriptions.create!(
      provider: "mollie", provider_subscription_id: "sub_#{SecureRandom.hex(4)}", plan_key: "lawrelay_office", status: "pending", amount_cents: 4900
    )
    payment = account.billing_payments.create!(
      subscription:, provider: "mollie", provider_payment_id: "tr_#{SecureRandom.hex(4)}", status: "pending", amount_cents: 5929
    )
    [ account, subscription, payment ]
  end

  def process_with_provider_status(payment_id, status)
    gateway = Object.new
    gateway.define_singleton_method(:payment) { |_id| { "status" => status } }

    with_release_mode("paid") do
      Billing::MollieWebhookProcessor.new(
        payment_id:,
        payload: { "id" => payment_id },
        gateway:
      ).call
    end
  end

  def with_release_mode(mode)
    original = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = mode
    yield
  ensure
    original.nil? ? ENV.delete("LAWRELAY_RELEASE_MODE") : ENV["LAWRELAY_RELEASE_MODE"] = original
  end
end
