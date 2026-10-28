module Webhooks
  class MollieController < ActionController::Base
    skip_forgery_protection

    def create
      payment_id = params[:id].to_s
      return head :bad_request if payment_id.blank?

      Billing::MollieWebhookProcessor.new(payment_id:, payload: request.request_parameters).call
      head :ok
    rescue Billing::MollieGateway::ConfigurationError
      head :service_unavailable
    rescue Billing::MollieGateway::RemoteError
      head :bad_gateway
    rescue ActiveRecord::RecordInvalid
      head :unprocessable_content
    end
  end
end
