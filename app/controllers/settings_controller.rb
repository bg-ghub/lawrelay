class SettingsController < ApplicationController
  before_action :load_records
  rate_limit to: 3, within: 1.minute, only: :update, if: :profile_import_request?, by: -> { current_user&.id },
    with: :profile_import_rate_limited

  def show
  end

  def update
    return preview_directory_profile if profile_import_request?

    profile_requires_review = profile_review_required?
    directory_identity_changed = directory_identity_changed?
    firm_requires_review = firm_review_required?

    ApplicationRecord.transaction do
      @user.assign_attributes(user_params)
      @profile.assign_attributes(profile_params)
      clear_directory_evidence! if directory_identity_changed
      reset_profile_verification! if profile_requires_review || directory_identity_changed

      if @can_manage_firm
        @firm.assign_attributes(firm_params)
        reset_firm_verification! if firm_requires_review
      end

      @user.save!
      @profile.save!
      @firm.save! if @can_manage_firm
      record_changes!(profile_requires_review:, firm_requires_review:)
    end

    delivery_ready = Onboarding::Delivery.request(@user, email: false, directory: directory_identity_changed && !protected_profile?(@profile))
    redirect_to settings_path(locale: @user.locale), notice: update_notice(profile_requires_review || directory_identity_changed, firm_requires_review),
      alert: (t("auth.verification_status.queue_unavailable") unless delivery_ready)
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_content
  end

  private

  def profile_import_request?
    params[:settings_action] == "import_profile"
  end

  def preview_directory_profile
    return head :forbidden if @user.system_admin?

    result = Directory::ProfileImport.call(
      profile_url: @profile.directory_profile_url,
      full_name: @profile.directory_name.presence || @user.full_name
    )
    assign_preview_values
    imported = result.success? && (result.profile_attributes.any? || (@can_manage_firm && result.firm_attributes.any?))
    if imported
      @profile.assign_attributes(result.profile_attributes)
      @firm.assign_attributes(result.firm_attributes) if @can_manage_firm
      flash.now[:notice] = t("profile_import.preview")
    else
      key = result.status == :missing_profile ? "missing_profile" : "unavailable"
      flash.now[:alert] = t("profile_import.#{key}")
    end
    mark_profile_import_preview
    render :show, status: imported ? :ok : :unprocessable_content
  end

  def profile_import_rate_limited
    assign_preview_values
    flash.now[:alert] = t("profile_import.rate_limited")
    mark_profile_import_preview
    render :show, status: :too_many_requests
  end

  def mark_profile_import_preview
    @profile_import_preview = [ @user, @profile, (@firm if @can_manage_firm) ].compact.any?(&:changed?)
  end

  def assign_preview_values
    @user.assign_attributes(user_params)
    @profile.assign_attributes(profile_params)
    @firm.assign_attributes(firm_params) if @can_manage_firm
  end

  def load_records
    @user = current_user
    @profile = @user.lawyer_profile || @user.build_lawyer_profile
    @firm = current_firm
    @can_manage_firm = @firm.present? && current_user.firm_administrator?(@firm)
  end

  def user_params
    params.fetch(:account, {}).permit(:first_name, :last_name, :locale)
  end

  def profile_params
    permitted = params.fetch(:profile, {}).permit(
      :bar_admission_year, :availability_note,
      spoken_languages: [], practice_areas: [], court_preferences: []
    )
    permitted[:spoken_languages] = list_values(permitted[:spoken_languages]) if permitted.key?(:spoken_languages)
    permitted[:practice_areas] = list_values(permitted[:practice_areas]) if permitted.key?(:practice_areas)
    permitted[:court_preferences] = list_values(permitted[:court_preferences]) if permitted.key?(:court_preferences)
    permitted
  end

  def firm_params
    params.fetch(:firm, {}).permit(
      :name, :enterprise_number, :vat_number, :billing_email, :phone,
      :address_line_1, :postal_code, :city
    )
  end

  def profile_review_required?
    return false if @profile.new_record?

    profile_params.to_h.slice("professional_email").any? do |attribute, value|
      @profile.public_send(attribute).to_s != value.to_s.strip
    end
  end

  def directory_identity_changed?
    return false if @profile.new_record?

    user_params.to_h.slice("first_name", "last_name").any? do |attribute, value|
      @user.public_send(attribute).to_s != value.to_s.strip
    end
  end

  def firm_review_required?
    return false unless @can_manage_firm

    firm_params.to_h.slice("name", "enterprise_number", "vat_number").any? do |attribute, value|
      @firm.public_send(attribute).to_s != value.to_s.strip
    end
  end

  def reset_profile_verification!
    return if protected_profile?(@profile)

    @profile.assign_attributes(verification_status: "pending", verified_at: nil, verification_note: nil)
  end

  def clear_directory_evidence!
    @profile.assign_attributes(
      directory_profile_id: nil,
      directory_name: nil,
      directory_email: nil,
      directory_checked_at: nil,
      directory_email_verified_at: nil,
      directory_confirmation_requested_at: nil,
      directory_identity_digest: nil
    )
  end

  def protected_profile?(profile)
    profile.verification_status.in?(%w[rejected suspended])
  end

  def reset_firm_verification!
    return if @firm.verification_status.in?(%w[rejected suspended])

    @firm.assign_attributes(verification_status: "pending", verified_at: nil)
  end

  def record_changes!(profile_requires_review:, firm_requires_review:)
    changed_models = [ @user, @profile, (@firm if @can_manage_firm) ].compact.select(&:saved_changes?)
    changed_models.each do |record|
      AuditEvent.create!(
        auditable: record,
        actor_user: @user,
        firm: @firm,
        action: "account.updated",
        metadata: { changed_fields: record.saved_changes.keys, profile_requires_review:, firm_requires_review: }
      )
    end
  end

  def update_notice(profile_requires_review, firm_requires_review)
    return t("settings.notices.review_required") if profile_requires_review || firm_requires_review

    t("settings.notices.updated")
  end

  def list_values(values)
    Array(values).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?).uniq
  end
end
