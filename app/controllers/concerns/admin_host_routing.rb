module AdminHostRouting
  extend ActiveSupport::Concern

  included do
    prepend_before_action :route_admin_host
    helper_method :admin_host?, :main_site_url, :authentication_login_path, :administrator_login_url
  end

  private

  def admin_host?
    SiteHosts.admin?(request.host)
  end

  def main_site_url
    SiteHosts.main_url(root_path)
  end

  def authentication_login_path
    admin_host? ? admin_login_path : new_session_path
  end

  def administrator_login_url
    admin_login_url(host: SiteHosts.admin_host, protocol: SiteHosts.protocol)
  end

  def route_admin_host
    return unless admin_host?
    return if controller_path.start_with?("admin/")
    return redirect_to admin_login_path, status: :see_other if controller_path == "passwords"
    return redirect_to admin_users_path, status: :see_other if controller_path == "email_changes"
    return if controller_path == "email_verifications"
    return if controller_path == "sessions" && action_name == "destroy"

    if controller_path == "home" && action_name == "index"
      redirect_to admin_users_path
    elsif controller_path == "sessions"
      redirect_to admin_login_path, status: :see_other
    else
      path = request.get? || request.head? ? request.fullpath : root_path
      redirect_to SiteHosts.main_url(path), allow_other_host: true, status: :see_other
    end
  end
end
