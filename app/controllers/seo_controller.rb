class SeoController < ActionController::Base
  PUBLIC_PATHS = [
    :root,
    :privacy,
    :terms,
    :cookies,
    :legal_notice
  ].freeze
  PRIVATE_PATHS = %w[
    assignments dashboard admin billing settings session passwords registration
    verification_status email-verification notifications reports privacy_requests
  ].freeze

  def robots
    if SiteHosts.admin?(request.host)
      return render plain: "User-agent: *\nDisallow: /\n", content_type: "text/plain"
    end

    disallowed_paths = PRIVATE_PATHS + I18n.available_locales.flat_map do |locale|
      PRIVATE_PATHS.map { |path| "#{locale}/#{path}" }
    end
    rules = disallowed_paths.map { |path| "Disallow: /#{path}" }.join("\n")

    render plain: "User-agent: *\n#{rules}\n\nSitemap: #{sitemap_url_for_host}\n", content_type: "text/plain"
  end

  def sitemap
    if SiteHosts.admin?(request.host)
      return redirect_to SiteHosts.main_url("/sitemap.xml"), allow_other_host: true
    end

    paths = PUBLIC_PATHS
    paths += [ :pricing ] if ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
    @urls = I18n.available_locales.flat_map do |locale|
      paths.map { |path| public_url(path, locale) }
    end

    render formats: :xml
  end

  private

  def public_url(path, locale)
    public_send("#{path}_url", locale:, **seo_url_options)
  end

  def sitemap_url_for_host
    url_for(controller: "/seo", action: :sitemap, format: :xml, only_path: false, **seo_url_options)
  end

  def seo_url_options
    if Rails.env.production?
      { host: ENV.fetch("APP_HOST", "lawrelay.be"), protocol: ENV.fetch("APP_PROTOCOL", "https") }
    else
      { host: request.host, port: request.optional_port, protocol: request.protocol.delete_suffix("://") }
    end
  end
end
