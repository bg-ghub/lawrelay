class PwaController < ActionController::Base
  # This public script is fetched by the browser's worker loader, not XHR.
  # Its route accepts only GET/HEAD and contains no session or account data.
  skip_forgery_protection only: :service_worker

  before_action :require_main_host
  before_action :set_public_metadata_headers

  def manifest
    locale = params[:locale].presence_in(I18n.available_locales.map(&:to_s)) || I18n.default_locale
    I18n.with_locale(locale) do
      render :manifest, formats: [ :json ], content_type: "application/manifest+json", layout: false
    end
  end

  def service_worker
    response.set_header("Service-Worker-Allowed", "/")
    render :"service-worker", formats: [ :js ], content_type: "application/javascript", layout: false
  end

  private

  def require_main_host
    head :not_found unless request.host.casecmp?(SiteHosts.app_host) && !SiteHosts.admin?(request.host)
  end

  def set_public_metadata_headers
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
  end
end
