module Directory
  class SignupPreview
    PURPOSE = "directory-signup-preview".freeze
    PROFILE_FIELDS = %w[spoken_languages practice_areas].freeze
    LIFETIME = 20.minutes

    def self.issue(result)
      raise ArgumentError, "A successful profile lookup is required" unless result.success?

      verifier.generate({ "profile_url" => result.profile_url, "name" => result.name,
        "profile_attributes" => result.profile_attributes.stringify_keys.slice(*PROFILE_FIELDS) },
        purpose: PURPOSE, expires_in: LIFETIME)
    end

    # Imported preferences are never directory/email verification evidence.
    def self.apply(profile, user:, token:)
      return true if token.blank?
      return false unless token.is_a?(String) && token.bytesize <= 16_384

      payload = verifier.verified(token, purpose: PURPOSE)
      return false unless payload.is_a?(Hash) && payload["profile_url"].present? &&
        payload["profile_url"] == AdvocaatBeProfileLookup.canonical_profile_url(profile.directory_profile_url) &&
        AdvocaatBeProfileLookup.names_match?(payload["name"], user.full_name)

      attributes = payload["profile_attributes"]
      return false unless attributes.is_a?(Hash) && (attributes.keys - PROFILE_FIELDS).empty?
      return false unless attributes.values.all? { |values| values.is_a?(Array) && values.size <= 20 && values.all? { |value| value.is_a?(String) && value.present? && value.length <= 100 } }

      profile.assign_attributes(attributes)
      true
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      false
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier
  end
end
