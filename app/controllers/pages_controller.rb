class PagesController < ApplicationController
  allow_unauthenticated_access

  LEGAL_VERSION = Date.new(2026, 10, 28)
  OPERATOR_ENV = {
    legal_name: "LAWRELAY_LEGAL_NAME",
    registered_address: "LAWRELAY_REGISTERED_ADDRESS",
    enterprise_number: "LAWRELAY_ENTERPRISE_NUMBER",
    vat_number: "LAWRELAY_VAT_NUMBER",
    legal_email: "LAWRELAY_LEGAL_EMAIL",
    privacy_email: "LAWRELAY_PRIVACY_EMAIL",
    support_email: "LAWRELAY_SUPPORT_EMAIL",
    phone: "LAWRELAY_PHONE",
    professional_body: "LAWRELAY_PROFESSIONAL_BODY",
    professional_rules_url: "LAWRELAY_PROFESSIONAL_RULES_URL"
  }.freeze
  REQUIRED_OPERATOR_FIELDS = %i[legal_name registered_address enterprise_number legal_email phone].freeze

  before_action :set_page_context

  def pricing; end

  def privacy; end

  def terms; end

  def cookie_policy; end

  def legal_notice; end

  private

  def set_page_context
    @legal_version = LEGAL_VERSION.iso8601
    @operator = OPERATOR_ENV.transform_values { |env_name| ENV[env_name].presence }
    @operator_configured = REQUIRED_OPERATOR_FIELDS.all? { |field| @operator[field].present? }
  end
end
