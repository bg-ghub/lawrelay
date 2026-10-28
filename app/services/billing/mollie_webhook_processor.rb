module Billing
  class MollieWebhookProcessor
    def initialize(payment_id:, payload: {}, gateway: MollieGateway.new)
      @payment_id = payment_id
      @payload = payload
      @gateway = gateway
    end

    def call
      return unless paid_release?

      event = register_event
      payment = BillingPayment.find_by(provider: "mollie", provider_payment_id: @payment_id)
      return event.update!(status: "ignored", processed_at: Time.current) unless payment

      provider_payment = @gateway.payment(@payment_id)
      provider_status = provider_payment.fetch("status")
      ApplicationRecord.transaction do
        event.lock!
        payment.lock!
        apply_provider_status(payment, provider_status)
        event.update!(
          status: "processed",
          processed_at: Time.current,
          payload: @payload.merge("provider_status" => provider_status),
          payload_digest: Digest::SHA256.hexdigest(@payload.merge("provider_status" => provider_status).to_json),
          error_message: nil
        )
      end
      event
    rescue StandardError => error
      event&.update!(status: "failed", error_message: error.message.truncate(1_000))
      raise
    end

    private

    def paid_release?
      ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
    end

    def register_event
      digest = Digest::SHA256.hexdigest(@payload.to_json)
      WebhookEvent.find_or_create_by!(provider: "mollie", external_id: @payment_id) do |event|
        event.payload = @payload
        event.payload_digest = digest
      end
    end

    def apply_provider_status(payment, provider_status)
      case provider_status
      when "paid"
        unless payment.status.in?(%w[paid refunded charged_back])
          payment.paid!
          activate_subscription(payment.subscription)
        end
      when "open", "pending", "authorized"
        payment.update!(status: "open") if payment.status.in?(%w[pending open])
      when "failed", "expired", "canceled"
        unless payment.status == "paid"
          payment.update!(status: provider_status == "canceled" ? "cancelled" : provider_status)
          payment.subscription&.update!(status: "past_due")
        end
      when "refunded"
        unless payment.status == "refunded"
          payment.refunded!
          revoke_subscription(payment.subscription)
        end
      when "charged_back"
        unless payment.status == "charged_back"
          payment.charged_back!
          revoke_subscription(payment.subscription)
        end
      else
        payment.update!(status: "pending") if payment.status.in?(%w[pending open])
      end
    end

    def activate_subscription(subscription)
      return unless subscription
      return if subscription.terminal? || subscription.billing_account.status.in?(%w[cancelled suspended])

      subscription.update!(status: "active", starts_at: subscription.starts_at || Time.current,
                           current_period_ends_at: 1.month.from_now)
      account = subscription.billing_account
      account.update!(provider: "mollie", plan_key: "lawrelay_office", status: "active")
      subscription.invoices.where.not(status: "paid").find_each { |invoice| invoice.mark_paid! }
    end

    def revoke_subscription(subscription)
      return unless subscription

      account = subscription.billing_account
      subscription.update!(status: "suspended") unless subscription.status.in?(%w[cancelled suspended])
      account.update!(status: "suspended") unless account.status == "cancelled"
    end
  end
end
