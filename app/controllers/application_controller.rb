class ApplicationController < ActionController::Base
  include Authentication
  include AdminHostRouting

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :switch_locale, prepend: true
  helper_method :current_user, :current_firm

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  def default_url_options
    { locale: I18n.locale }
  end

  private

  def current_user
    Current.user
  end

  def current_firm
    current_user&.primary_firm
  end

  def require_verified_lawyer
    return if current_user&.marketplace_verified?

    redirect_to verification_status_path, alert: t("auth.verification.marketplace_required")
  end

  def require_firm_administrator
    return if current_user&.firm_administrator?(current_firm)

    redirect_to dashboard_path, alert: t("auth.authorization.firm_admin_required")
  end

  def require_posting_access
    return if current_firm&.posting_access?

    redirect_to billing_path, alert: t("billing.notices.posting_plan_required")
  end

  def require_system_admin
    return if current_user&.system_admin?

    redirect_to(admin_host? ? admin_login_path : root_path, alert: t("auth.authorization.admin_required"))
  end

  def switch_locale(&)
    locale = params[:locale].presence_in(I18n.available_locales.map(&:to_s)) || Current.user&.locale || I18n.default_locale
    I18n.with_locale(locale, &)
  end
end
