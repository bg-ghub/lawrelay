module Billing
  class ManualPaymentConfirmationService
    class InvalidConfirmation < StandardError; end

    Result = Data.define(:subscription, :invoice, :payment, :activated)

    def initialize(payment:, actor_user:, payment_reference:)
      @payment = payment
      @actor_user = actor_user
      @payment_reference = payment_reference.to_s.strip
    end

    def call
      validate_operator!
      validate_reference!

      ApplicationRecord.transaction do
        @payment.lock!
        subscription = @payment.subscription
        raise InvalidConfirmation, "Manual payment has no subscription" unless subscription

        subscription.lock!
        account = subscription.billing_account
        account.lock!
        invoice = subscription.invoices.order(created_at: :desc).first
        raise InvalidConfirmation, "Manual payment has no invoice" unless invoice
        raise InvalidConfirmation, "Manual payment does not match invoice total" unless @payment.amount_cents == invoice.total_cents
        raise InvalidConfirmation, "Cancelled or suspended billing cannot be reactivated" if subscription.terminal? || account.status.in?(%w[cancelled suspended])

        return Result.new(subscription:, invoice:, payment: @payment, activated: false) if @payment.status == "paid"

        unless @payment.status.in?(%w[pending open])
          raise InvalidConfirmation, "Only a pending manual payment can be confirmed"
        end

        paid_at = Time.current
        @payment.update!(status: "paid", paid_at:)
        invoice.update!(status: "paid", paid_on: paid_at.to_date, external_reference: @payment_reference)
        subscription.update!(
          status: "active",
          starts_at: paid_at,
          current_period_ends_at: paid_at + 1.month
        )
        account.update!(provider: "manual", plan_key: "lawrelay_office", status: "active")
        AuditEvent.create!(
          actor_user: @actor_user,
          firm: account.firm,
          auditable: @payment,
          action: "billing.manual_payment_confirmed",
          metadata: {
            "invoice_number" => invoice.number,
            "payment_reference" => @payment_reference,
            "subscription_id" => subscription.id
          }
        )

        Result.new(subscription:, invoice:, payment: @payment, activated: true)
      end
    end

    private

    def validate_operator!
      raise InvalidConfirmation, "A system administrator is required" unless @actor_user&.system_admin?
      raise InvalidConfirmation, "Only manual payments can be confirmed here" unless @payment.provider == "manual"
    end

    def validate_reference!
      raise InvalidConfirmation, "A bank or Peppol payment reference is required" if @payment_reference.blank?
      raise InvalidConfirmation, "Payment reference is too long" if @payment_reference.length > 160
    end
  end
end
