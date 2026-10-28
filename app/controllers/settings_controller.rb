class SettingsController < ApplicationController
  before_action :load_records

  def show
  end

  def update
    email_changed = user_params[:email_address].present? &&
      user_params[:email_address].strip.casecmp?(@user.email_address) == false
    profile_requires_review = profile_review_required?
    firm_requires_review = firm_review_required?

    ApplicationRecord.transaction do
      @user.assign_attributes(user_params)
      @user.email_verified_at = nil if email_changed

      @profile.assign_attributes(profile_params)
      reset_profile_verification! if profile_requires_review

      if @can_manage_firm
        @firm.assign_attributes(firm_params)
        reset_firm_verification! if firm_requires_review
      end

      @user.save!
      @profile.save!
      @firm.save! if @can_manage_firm
      record_changes!(email_changed:, profile_requires_review:, firm_requires_review:)
    end

    EmailVerificationMailer.verify(@user).deliver_later if email_changed
    redirect_to settings_path(locale: @user.locale), notice: update_notice(email_changed, profile_requires_review, firm_requires_review)
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_content
  end

  private

  def load_records
    @user = current_user
    @profile = @user.lawyer_profile || @user.build_lawyer_profile
    @firm = current_firm
    @can_manage_firm = @firm.present? && current_user.firm_administrator?(@firm)
  end

  def user_params
    params.fetch(:account, {}).permit(:first_name, :last_name, :email_address, :locale)
  end

  def profile_params
    permitted = params.fetch(:profile, {}).permit(
      :bar_association, :bar_number, :professional_email, :bar_admission_year, :availability_note,
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

    profile_params.to_h.slice("bar_association", "bar_number", "professional_email").any? do |attribute, value|
      @profile.public_send(attribute).to_s != value.to_s.strip
    end
  end

  def firm_review_required?
    return false unless @can_manage_firm

    firm_params.to_h.slice("name", "enterprise_number", "vat_number").any? do |attribute, value|
      @firm.public_send(attribute).to_s != value.to_s.strip
    end
  end

  def reset_profile_verification!
    @profile.assign_attributes(verification_status: "pending", verified_at: nil, verification_note: nil)
  end

  def reset_firm_verification!
    @firm.assign_attributes(verification_status: "pending", verified_at: nil)
  end

  def record_changes!(email_changed:, profile_requires_review:, firm_requires_review:)
    changed_models = [ @user, @profile, (@firm if @can_manage_firm) ].compact.select(&:saved_changes?)
    changed_models.each do |record|
      AuditEvent.create!(
        auditable: record,
        actor_user: @user,
        firm: @firm,
        action: "account.updated",
        metadata: { changed_fields: record.saved_changes.keys, email_changed:, profile_requires_review:, firm_requires_review: }
      )
    end
  end

  def update_notice(email_changed, profile_requires_review, firm_requires_review)
    return t("settings.notices.email_reverification") if email_changed
    return t("settings.notices.review_required") if profile_requires_review || firm_requires_review

    t("settings.notices.updated")
  end

  def list_values(values)
    Array(values).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?).uniq
  end
end
