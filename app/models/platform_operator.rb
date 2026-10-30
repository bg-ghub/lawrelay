class PlatformOperator
  ENVIRONMENT_FIELDS = {
    legal_name: "LAWRELAY_LEGAL_NAME",
    registered_address: "LAWRELAY_REGISTERED_ADDRESS",
    enterprise_number: "LAWRELAY_ENTERPRISE_NUMBER",
    vat_number: "LAWRELAY_VAT_NUMBER",
    legal_email: "LAWRELAY_LEGAL_EMAIL",
    privacy_email: "LAWRELAY_PRIVACY_EMAIL",
    support_email: "LAWRELAY_SUPPORT_EMAIL",
    phone: "LAWRELAY_PHONE"
  }.freeze
  REQUIRED_FIELDS = %i[legal_name registered_address enterprise_number vat_number legal_email privacy_email support_email phone].freeze

  def self.details
    defaults = YAML.safe_load_file(Rails.root.join("config/operator.yml")).symbolize_keys
    ENVIRONMENT_FIELDS.to_h do |field, variable|
      [ field, ENV.key?(variable) ? ENV[variable].presence : defaults[field].presence ]
    end
  end

  def self.configured?
    operator = details
    REQUIRED_FIELDS.all? { |field| operator[field].present? }
  end
end
