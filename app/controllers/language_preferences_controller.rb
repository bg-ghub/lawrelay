class LanguagePreferencesController < ApplicationController
  def update
    return head :forbidden if admin_host? && !current_user.system_admin?

    locale = params[:preferred_locale]
    return head :unprocessable_content unless User::LOCALES.include?(locale)

    current_user.with_lock do
      return head :forbidden unless current_user.active?

      current_user.update!(locale:)
    end
    head :no_content
  end
end
