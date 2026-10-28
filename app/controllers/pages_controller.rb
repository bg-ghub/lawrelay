class PagesController < ApplicationController
  allow_unauthenticated_access

  LEGAL_VERSION = Date.new(2026, 10, 28)
  OPERATOR_ENV = PlatformOperator::ENVIRONMENT_FIELDS
  REQUIRED_OPERATOR_FIELDS = PlatformOperator::REQUIRED_FIELDS

  before_action :set_page_context

  def pricing; end

  def privacy; end

  def terms; end

  def cookie_policy; end

  def legal_notice; end

  private

  def set_page_context
    @legal_version = LEGAL_VERSION.iso8601
    @operator = PlatformOperator.details
    @operator_configured = REQUIRED_OPERATOR_FIELDS.all? { |field| @operator[field].present? }
  end
end
