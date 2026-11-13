class SettingsController < ApplicationController
  before_action :load_records
  rate_limit to: 3, within: 1.minute, only: :update, if: :profile_import_request?, by: -> { current_user&.id },
    with: :profile_import_rate_limited

  def show
  end

  def update
    return refresh_directory_profile if profile_import_request?

    ApplicationRecord.transaction do
      @user.assign_attributes(user_params)
      @profile.assign_attributes(preference_params)
      @user.save!
      @profile.save!
      record_changes!
    end

    destination_locale = @user.locale
    redirect_to settings_path(locale: destination_locale), notice: I18n.t("settings.notices.updated", locale: destination_locale)
  rescue ActiveRecord::RecordInvalid
    render :show, formats: :html, status: :unprocessable_content
  end

  private

  def profile_import_request?
    params[:settings_action].in?(%w[refresh_profile import_profile])
  end

  def refresh_directory_profile
    return head :forbidden if @user.system_admin?

    result = Directory::ProfileSync.call(user: @user, actor: @user)
    if result.success?
      return redirect_to settings_path, notice: t("profile_import.updated")
    end

    key = result.status.in?(%i[missing_profile empty]) ? result.status : :unavailable
    key = :directory_unavailable if result.status == :unavailable
    @directory_refresh_error = t("profile_import.#{key}")
    render :show, formats: :html, status: :unprocessable_content
  end

  def profile_import_rate_limited
    @directory_refresh_error = t("profile_import.rate_limited")
    render :show, formats: :html, status: :too_many_requests
  end

  def load_records
    @user = current_user
    @profile = @user.lawyer_profile || @user.build_lawyer_profile
    @firm = current_firm
  end

  def user_params
    account = parameter_group(:account)
    return account.permit(:locale) if @user.system_admin?

    account.permit(:locale, :new_assignment_alerts, :assignment_update_emails).select do |key, value|
      key == "locale" || [ "0", "1", false, true ].include?(value)
    end
  end

  def preference_params
    return {} if @user.system_admin?

    parameter_group(:preferences).permit(:bar_admission_year)
  end

  def parameter_group(name)
    value = params[name]
    return ActionController::Parameters.new if value.nil?
    raise ActionController::ParameterMissing, name unless value.is_a?(ActionController::Parameters)

    value
  end

  def record_changes!
    changed_models = [ @user, @profile ].select(&:saved_changes?)
    changed_models.each do |record|
      AuditEvent.create!(
        auditable: record,
        actor_user: @user,
        firm: @firm,
        action: "account.updated",
        metadata: { changed_fields: record.saved_changes.keys, profile_requires_review: false }
      )
    end
  end
end
