class SettingsController < ApplicationController
  before_action :load_records
  rate_limit to: 3, within: 1.minute, only: :update, if: :profile_import_request?, by: -> { current_user&.id },
    with: :profile_import_rate_limited

  def show
  end

  def update
    return refresh_directory_profile if profile_import_request?

    directory_identity_changed = directory_identity_changed?

    ApplicationRecord.transaction do
      @user.assign_attributes(user_params)
      @profile.assign_attributes(preference_params)
      clear_directory_evidence! if directory_identity_changed
      reset_profile_verification! if directory_identity_changed

      @user.save!
      @profile.save!
      record_changes!(profile_requires_review: directory_identity_changed)
    end

    delivery_ready = Onboarding::Delivery.request(@user, email: false, directory: directory_identity_changed && !protected_profile?(@profile))
    destination_locale = @user.locale
    redirect_to settings_path(locale: destination_locale), notice: update_notice(directory_identity_changed, locale: destination_locale),
      alert: (I18n.t("auth.verification_status.queue_unavailable", locale: destination_locale) unless delivery_ready)
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
    parameter_group(:account).permit(:first_name, :last_name, :locale)
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

  def directory_identity_changed?
    return false if @profile.new_record?

    user_params.to_h.slice("first_name", "last_name").any? do |attribute, value|
      @user.public_send(attribute).to_s != value.to_s.strip
    end
  end

  def reset_profile_verification!
    return if protected_profile?(@profile)

    @profile.assign_attributes(verification_status: "pending", verified_at: nil, verification_note: nil)
  end

  def clear_directory_evidence!
    @profile.clear_email_review
    @profile.assign_attributes(
      directory_profile_id: nil,
      directory_name: nil,
      directory_email: nil,
      directory_professional_address: nil,
      directory_bar_name: nil,
      directory_checked_at: nil,
      directory_email_verified_at: nil,
      directory_confirmation_requested_at: nil,
      directory_identity_digest: nil
    )
  end

  def protected_profile?(profile)
    profile.verification_status.in?(%w[rejected suspended])
  end

  def record_changes!(profile_requires_review:)
    changed_models = [ @user, @profile ].select(&:saved_changes?)
    changed_models.each do |record|
      AuditEvent.create!(
        auditable: record,
        actor_user: @user,
        firm: @firm,
        action: "account.updated",
        metadata: { changed_fields: record.saved_changes.keys, profile_requires_review: }
      )
    end
  end

  def update_notice(profile_requires_review, locale: I18n.locale)
    return I18n.t("settings.notices.review_required", locale:) if profile_requires_review

    I18n.t("settings.notices.updated", locale:)
  end
end
