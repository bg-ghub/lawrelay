# frozen_string_literal: true

module GeoChallenge
  extend ActiveSupport::Concern

  included do
    before_action :enforce_geo_challenge
  end

  private

  def enforce_geo_challenge
    return unless GeoCountry.challenge_enabled?
    return unless anonymous_public_page?
    return if geo_verified? || GeoCountry.country_for(request.remote_ip) == "BE"

    cookies.signed[:geo_return_to] = {
      value: request.path,
      expires: 10.minutes.from_now,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
    redirect_to geo_challenge_path(locale: I18n.locale), status: :see_other
  end

  def anonymous_public_page?
    return false if admin_host? || authenticated?

    controller_path == "home" || (controller_path == "pages" && action_name.in?(%w[privacy terms cookie_policy legal_notice]))
  end

  def geo_verified?
    cookies.signed[:geo_verified] == "verified"
  end
end
