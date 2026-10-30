module BusinessRegistry
  class Preview
    PURPOSE = "kbo-billing-preview".freeze
    FIELDS = %w[name enterprise_number address_line_1 postal_code city].freeze

    def self.issue(result)
      verifier.generate({ "attributes" => result.attributes.stringify_keys.slice(*FIELDS),
        "snapshot_date" => result.snapshot_date.iso8601 }, purpose: PURPOSE, expires_in: 1.hour)
    end

    # Provenance is derived from a server-signed response, never from a submitted
    # source/date. Editing a value drops attribution for that field only.
    def self.apply(record, token: nil, fallback: nil)
      prefix = record.is_a?(Assignment) ? "invoice_" : ""
      metadata_field = "#{prefix}kbo_details"
      current = values_for(record, prefix:)
      payload = verifier.verified(token, purpose: PURPOSE) if token.present?

      if payload.is_a?(Hash) && same_number?(current, payload["attributes"])
        original = payload["attributes"]
        date = payload["snapshot_date"]
        fields = original.keys & FIELDS
      elsif record.persisted?
        metadata = record.public_send(metadata_field)
        date = metadata["snapshot_date"]
        fields = Array(metadata["fields"]) & FIELDS
        original = FIELDS.to_h { |field| [ field, record.attribute_in_database("#{prefix}#{field}") ] }
      elsif fallback
        metadata = fallback.kbo_details
        date = metadata["snapshot_date"]
        fields = Array(metadata["fields"]) & FIELDS
        original = values_for(fallback)
      end

      retained = if date && same_number?(current, original)
        Array(fields).select { |field| normalize(field, current[field]) == normalize(field, original[field]) }
      else
        []
      end
      metadata = valid_date?(date) && retained.any? ? { "snapshot_date" => date, "fields" => retained } : {}
      record.public_send("#{metadata_field}=", metadata)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      record.public_send("#{metadata_field}=", {})
    end

    def self.values_for(record, prefix: "")
      FIELDS.to_h { |field| [ field, record.public_send("#{prefix}#{field}") ] }
    end

    def self.same_number?(left, right)
      right.is_a?(Hash) && Firm.valid_enterprise_number?(left["enterprise_number"]) &&
        normalize("enterprise_number", left["enterprise_number"]) == normalize("enterprise_number", right["enterprise_number"])
    end

    def self.normalize(field, value)
      field == "enterprise_number" ? Firm.normalize_enterprise_number(value) : value.to_s.strip
    end

    def self.valid_date?(value)
      value.is_a?(String) && Date.iso8601(value).iso8601 == value
    rescue Date::Error
      false
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :values_for, :same_number?, :normalize, :valid_date?, :verifier
  end
end
