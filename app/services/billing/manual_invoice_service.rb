module Billing
  class ManualInvoiceService
    Result = Data.define(:subscription, :invoice, :payment)

    def initialize(billing_account:, vat_rate_basis_points: default_vat_rate)
      @billing_account = billing_account
      @vat_rate_basis_points = vat_rate_basis_points
    end

    def call
      ActiveRecord::Base.transaction do
        @billing_account.lock!
        @billing_account.update!(provider: "manual", plan_key: "lawrelay_office", status: "pending") unless @billing_account.status == "active"
        subscription = @billing_account.current_subscription || create_subscription
        invoice = subscription.invoices.order(created_at: :desc).first || @billing_account.invoices.create!(
          subscription: subscription,
          subtotal_cents: subscription.amount_cents,
          vat_rate_basis_points: @vat_rate_basis_points,
          peppol_status: "manual_required"
        )
        invoice.issue! if invoice.status == "draft"
        payment = subscription.billing_payments.order(created_at: :desc).first || @billing_account.billing_payments.create!(
          subscription: subscription,
          provider: "manual",
          status: "pending",
          amount_cents: invoice.total_cents
        )

        Result.new(subscription:, invoice:, payment:)
      end
    end

    private

    def create_subscription
      @billing_account.subscriptions.create!(
        provider: "manual",
        plan_key: "lawrelay_office",
        status: "pending",
        amount_cents: 4900,
        starts_at: Time.current
      )
    end

    def default_vat_rate
      ENV.fetch("LAWRELAY_VAT_RATE_BASIS_POINTS", "2100").to_i
    end
  end
end
