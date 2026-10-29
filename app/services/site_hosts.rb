class SiteHosts
  def self.app_host
    ENV.fetch("APP_HOST", "lawrelay.be")
  end

  def self.admin_host
    ENV.fetch("ADMIN_HOST", "admin.#{app_host}")
  end

  def self.protocol
    ENV.fetch("APP_PROTOCOL", "https")
  end

  def self.admin?(host)
    host.casecmp?(admin_host)
  end

  def self.main_url(path)
    "#{protocol}://#{app_host}#{path}"
  end

  def self.account_url_options(user)
    return {} unless Rails.env.production? || ENV["APP_HOST"].present? || ENV["ADMIN_HOST"].present?

    { host: user.system_admin? ? admin_host : app_host, protocol: protocol }
  end
end
