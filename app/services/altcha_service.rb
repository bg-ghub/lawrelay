# frozen_string_literal: true

class AltchaService
  ALGORITHM = "SHA-256"
  MAX_NUMBER = 100_000
  TTL = 10.minutes
  MAX_PAYLOAD_BYTES = 2_048
  PURPOSE = "lawrelay-geo-v1"
  STRING_FIELDS = %w[challenge salt signature].freeze

  class << self
    def generate_challenge(nonce:, now: Time.current)
      salt = "#{nonce}?expires=#{(now + TTL).to_i}"
      challenge = OpenSSL::Digest::SHA256.hexdigest("#{salt}#{SecureRandom.random_number(MAX_NUMBER)}")
      { algorithm: ALGORITHM, challenge:, salt:, signature: signature(challenge, salt), maxnumber: MAX_NUMBER }
    end

    def verify_solution(payload, nonce:, now: Time.current)
      data = decode(payload)
      return false unless data && data["salt"].start_with?("#{nonce}?")

      expires = data["salt"].split("?expires=", 2).last.to_i
      return false unless expires.between?(now.to_i + 1, (now + TTL).to_i + 60)
      return false unless data["number"].is_a?(Integer) && data["number"].between?(0, MAX_NUMBER)
      return false unless secure_compare(OpenSSL::Digest::SHA256.hexdigest("#{data['salt']}#{data['number']}"), data["challenge"])

      return false unless secure_compare(signature(data["challenge"], data["salt"]), data["signature"])

      claim_once(nonce, expires - now.to_i)
    end

    private

    def decode(payload)
      return unless payload.is_a?(String) && payload.bytesize.between?(1, MAX_PAYLOAD_BYTES)

      data = JSON.parse(Base64.strict_decode64(payload))
      return unless data.is_a?(Hash) && data["algorithm"] == ALGORITHM && STRING_FIELDS.all? { |field| data[field].is_a?(String) }

      data
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def signature(challenge, salt)
      OpenSSL::HMAC.hexdigest("SHA256", hmac_key, [ PURPOSE, challenge, salt ].join("|"))
    end

    def hmac_key
      ENV.fetch("ALTCHA_HMAC_KEY") { Rails.application.secret_key_base }
    end

    def secure_compare(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end

    # A browser cookie can be restored from a prior copy. The proof therefore
    # needs a server-side, atomic claim as well as the browser-bound nonce.
    def claim_once(nonce, seconds)
      return false unless seconds.positive?

      Rails.cache.write(
        "altcha:geo:#{OpenSSL::Digest::SHA256.hexdigest(nonce)}",
        true,
        expires_in: seconds.seconds,
        unless_exist: true
      )
    rescue StandardError => error
      Rails.logger.warn("Altcha proof claim unavailable: #{error.class}")
      false
    end
  end
end
