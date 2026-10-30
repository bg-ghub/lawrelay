class CompanyLookupsController < ApplicationController
  allow_unauthenticated_access only: :create
  before_action :resume_session
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  rate_limit to: 5, within: 1.minute, only: :create,
    with: -> { render json: { status: "rate_limited", message: I18n.t("business_lookup.rate_limited") }, status: :too_many_requests }
  rate_limit to: 2_000, within: 1.day, name: "daily", by: -> { "all" }, only: :create, if: :lookup_request?,
    with: -> { render json: { status: "rate_limited", message: I18n.t("business_lookup.limit_reached") }, status: :too_many_requests }

  def create
    return head :forbidden if current_user&.system_admin?

    unless params[:enterprise_number].is_a?(String)
      return render json: { status: "invalid", message: I18n.t("business_lookup.invalid") }, status: :unprocessable_content
    end

    result = BusinessRegistry::PublicLookup.call(enterprise_number: params[:enterprise_number], locale: I18n.locale)
    if result.status == :ok
      render json: { status: "ok", attributes: result.attributes, token: BusinessRegistry::Preview.issue(result),
        source_date: result.snapshot_date.iso8601,
        source_label: helpers.business_lookup_source_label(snapshot_date: result.snapshot_date, fields: result.attributes.keys) }
    else
      status = { invalid: :unprocessable_content, not_found: :not_found }.fetch(result.status, :service_unavailable)
      render json: { status: result.status, message: I18n.t("business_lookup.#{result.status}") }, status:
    end
  end

  private

  def lookup_request?
    BusinessRegistry::PublicLookup.configured? && params[:enterprise_number].is_a?(String) &&
      Firm.valid_enterprise_number?(params[:enterprise_number])
  end
end
