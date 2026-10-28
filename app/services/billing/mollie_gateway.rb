require "net/http"
require "json"

module Billing
  class MollieGateway
    class ConfigurationError < StandardError; end
    class RemoteError < StandardError; end

    API_BASE = "https://api.mollie.com"

    def configured?
      api_key.present?
    end

    def payment(payment_id)
      request(:get, "/v2/payments/#{payment_id}")
    end

    private

    def api_key
      ENV["MOLLIE_API_KEY"]
    end

    def request(method, path)
      raise ConfigurationError, "Mollie is not configured" unless configured?

      uri = URI.join(API_BASE, path)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Accept"] = "application/json"

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
        http.request(request)
      end
      body = JSON.parse(response.body)
      return body if response.is_a?(Net::HTTPSuccess)

      raise RemoteError, "Mollie returned #{response.code}: #{body.fetch('detail', 'unknown error')}"
    rescue JSON::ParserError
      raise RemoteError, "Mollie returned an invalid response"
    end
  end
end
