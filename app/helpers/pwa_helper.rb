module PwaHelper
  def pwa_available?
    request.host.casecmp?(SiteHosts.app_host) &&
      !SiteHosts.admin?(request.host) &&
      !controller_path.start_with?("admin/")
  end
end
