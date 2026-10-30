module AnalyticsHelper
  UMAMI_ANALYTICS_HOST = "https://analytics.lawrelay.be".freeze
  UMAMI_PUBLIC_ACTIONS = [
    [ "home", "index" ],
    [ "pages", "privacy" ],
    [ "pages", "terms" ],
    [ "pages", "cookie_policy" ],
    [ "pages", "legal_notice" ]
  ].freeze

  def umami_analytics_enabled?
    umami_analytics_configured? && umami_analytics_public_page?
  end

  def umami_analytics_configured?
    Rails.env.production? && ENV["UMAMI_WEBSITE_ID"].present?
  end

  def umami_analytics_preferences_available?(environment: Rails.env, website_id: ENV["UMAMI_WEBSITE_ID"], admin: admin_host?)
    environment.production? && website_id.present? && !admin
  end

  def umami_analytics_public_page?
    request.get? &&
      !admin_host? &&
      !authenticated? &&
      umami_analytics_public_action?(controller_path:, action_name:)
  end

  def umami_analytics_public_action?(controller_path:, action_name:)
    UMAMI_PUBLIC_ACTIONS.include?([ controller_path, action_name ])
  end
end
