module Directory
  class SignupPreview
    PURPOSE = "directory-signup-preview".freeze
    PROFILE_FIELDS = %w[spoken_languages practice_areas].freeze
    LIFETIME = 20.minutes

    def self.issue(result)
      raise ArgumentError, "A successful profile lookup is required" unless result.success?

      verifier.generate({ "profile_url" => result.profile_url, "name" => result.name,
        "first_name" => result.first_name, "last_name" => result.last_name, "email_address" => result.email_address,
        "profile_attributes" => result.profile_attributes.stringify_keys.slice(*PROFILE_FIELDS) },
        purpose: PURPOSE, expires_in: LIFETIME)
    end

    # The listed email comes only from the server-signed directory result.
    # Possession of this preview still does not confirm the email or profession.
    def self.read(token:, profile_url:)
      return unless token.is_a?(String) && token.present? && token.bytesize <= 16_384

      payload = verifier.verified(token, purpose: PURPOSE)
      return unless payload.is_a?(Hash) && payload["profile_url"].present? &&
        payload["profile_url"] == AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      return unless payload["name"].is_a?(String) && payload["name"].present? && payload["name"].length <= 201
      return unless %w[first_name last_name].all? { |key| payload[key].is_a?(String) && payload[key].length <= 100 }
      email = payload["email_address"]
      return unless email.is_a?(String) && email.length <= 254 && email == email.strip.downcase && email.match?(URI::MailTo::EMAIL_REGEXP)

      attributes = payload["profile_attributes"]
      return unless attributes.is_a?(Hash) && (attributes.keys - PROFILE_FIELDS).empty?
      return unless attributes.values.all? { |values| values.is_a?(Array) && values.size <= 20 && values.all? { |value| value.is_a?(String) && value.present? && value.length <= 100 } }

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      nil
    end

    def self.apply(profile, user:, token:)
      payload = read(token:, profile_url: profile.directory_profile_url)
      return false unless payload && AdvocaatBeProfileLookup.names_match?(payload["name"], user.full_name) &&
        payload["email_address"] == user.email_address

      profile.assign_attributes(payload["profile_attributes"])
      true
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier
  end
end
