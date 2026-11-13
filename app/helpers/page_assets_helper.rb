module PageAssetsHelper
  SHARED_STYLESHEETS = %w[application footer_project product_bar pwa_install shared_flash].freeze
  AUTH_STYLESHEETS = %w[accessibility_beta auth-copy].freeze
  ASSIGNMENT_STYLESHEETS = %w[
    accessibility_beta assignment_datetime assignment_filters assignment_rates court_picker profile_import
    profile_preferences proposal_location proposal_travel searchable_select
  ].freeze
  ADMIN_STYLESHEETS = %w[
    admin_mfa admin_navigation admin_shell admin_users auth-copy registry_status searchable_select two_factor
  ].freeze

  def page_stylesheet_names
    shared = SHARED_STYLESHEETS.reject { |name| admin_host? && name.in?(%w[product_bar pwa_install]) }
    specific = if controller_path.start_with?("admin/")
      ADMIN_STYLESHEETS
    else
      case controller_path
      when "home"
        %w[home_pathways marketing_copy]
      when "pages"
        case action_name
        when "court_cover", "legal_assignments" then %w[product_pages]
        when "pricing" then %w[pricing_copy]
        else %w[legal_pages]
        end
      when "registrations"
        AUTH_STYLESHEETS + %w[account_flow profile_import registration_profile]
      when "verification_status"
        AUTH_STYLESHEETS + %w[account_flow profile_import verification_status]
      when "email_access_requests"
        AUTH_STYLESHEETS + %w[account_flow profile_import]
      when "sessions", "passwords", "email_verifications", "directory_verifications", "email_changes", "geo_challenges"
        AUTH_STYLESHEETS
      when "account_deletions"
        AUTH_STYLESHEETS + %w[account_deletion]
      when "two_factor_authentications"
        AUTH_STYLESHEETS + %w[admin_mfa two_factor]
      when "settings"
        %w[profile_import profile_preferences searchable_select two_factor]
      when "assignments", "proposals", "travel_estimates"
        ASSIGNMENT_STYLESHEETS
      when "dashboard"
        %w[assignment_rates profile_import profile_preferences proposal_location proposal_travel]
      when "notifications"
        %w[notifications]
      when "reports", "privacy_requests"
        %w[searchable_select]
      when "billing"
        %w[business_lookup searchable_select]
      else
        []
      end
    end

    (shared + specific).uniq.sort
  end

  def shared_stylesheet?(name)
    SHARED_STYLESHEETS.include?(name)
  end
end
