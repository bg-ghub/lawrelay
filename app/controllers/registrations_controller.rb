class RegistrationsController < ApplicationController
  TERMS_VERSION = "2026-11-02-deletion-grace"
  PRIVACY_VERSION = "2026-11-13-email-preferences"

  allow_unauthenticated_access
  rate_limit to: 5, within: 1.hour, only: :create,
    with: -> { redirect_to new_registration_path, alert: t("auth.registration.errors.rate_limited") }
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  rate_limit to: 5, within: 1.minute, name: "directory_preview", only: :preview,
    with: -> { render_preview_failure(:rate_limited, status: :too_many_requests) }
  rate_limit to: 500, within: 1.day, name: "directory_daily", by: -> { "all" }, only: :preview, if: :preview_lookup_request?,
    with: -> { render_preview_failure(:limit_reached, status: :too_many_requests) }
  rate_limit to: 5, within: 1.minute, name: "directory_name_search", only: :search,
    with: -> { render_search_failure(:rate_limited, status: :too_many_requests) }
  rate_limit to: 200, within: 1.day, name: "directory_name_daily", by: -> { "all" }, only: :search, if: :name_search_request?,
    with: -> { render_search_failure(:limit_reached, status: :too_many_requests) }

  def new
    prepare_form
  end

  def search
    result = Directory::AdvocaatBeNameSearch.call(name_query: name_search_query)
    return render_search_failure(result.status, status: result.status == :unavailable ? :service_unavailable : :unprocessable_content) unless result.success?

    respond_to do |format|
      format.json { render json: { status: "ok", candidates: result.candidates, truncated: result.truncated } }
      format.html do
        prepare_search_form
        @name_search_results = result.candidates
        @name_search_truncated = result.truncated
        render :new
      end
    end
  end

  def preview
    result = Directory::SignupProfile.call(profile_url: preview_profile_url)
    return render_preview_failure(result.status, status: result.status == :unavailable ? :service_unavailable : :unprocessable_content) unless result.success?

    token = Directory::SignupPreview.issue(result)
    respond_to do |format|
      format.json do
        render json: { status: "ok", profile_url: result.profile_url, name: result.name,
          first_name: result.first_name, last_name: result.last_name, email_address: result.email_address,
          profile_attributes: result.profile_attributes, token: }
      end
      format.html do
        attributes = preview_form_attributes
        attributes[:directory_profile_url] = result.profile_url
        attributes[:directory_preview_token] = token
        @terms_accepted = ActiveModel::Type::Boolean.new.cast(attributes[:terms_accepted])
        prepare_form(attributes)
        @directory_preview = result
        flash.now[:notice] = t("signup_profile.loaded")
        render :new
      end
    end
  end

  def create
    attributes = registration_params.to_h.symbolize_keys
    @terms_accepted = ActiveModel::Type::Boolean.new.cast(attributes.delete(:terms_accepted))
    prepare_form(attributes)

    unless @directory_identity
      @registration_errors << t("signup_profile.errors.invalid_preview")
      return render :new, status: :unprocessable_content
    end

    @user.accepted_terms_at = Time.current if @terms_accepted
    @user.accepted_terms_version = TERMS_VERSION if @terms_accepted
    # Record receipt of the privacy notice, not consent as a processing basis.
    @user.accepted_privacy_version = PRIVACY_VERSION if @terms_accepted
    profile_url_valid = Directory::AdvocaatBeProfileLookup.valid_profile_url?(attributes[:directory_profile_url])
    # Validate the signed source identity before choosing a different sign-in email.
    preview_valid = Directory::SignupPreview.apply(@lawyer_profile, user: @user, token: attributes[:directory_preview_token])
    prepare_alternative_email(attributes) if @request_alternative_email
    models_valid = @user.valid? & @firm.valid? & @lawyer_profile.valid?
    if @user.email_address.length > 254
      @user.errors.add(:email_address, :too_long, count: 254)
      models_valid = false
    end
    unless profile_url_valid
      @lawyer_profile.errors.add(:directory_profile_url, t("directory_onboarding.registration.invalid_profile_url"))
      models_valid = false
    end
    unless preview_valid
      @lawyer_profile.errors.add(:base, t("signup_profile.review"))
      models_valid = false
    end
    @user.errors.add(:base, t("auth.registration.errors.accept_terms")) unless @terms_accepted

    if @terms_accepted && models_valid
      persist_registration!
      start_new_session_for(@user)
      if Onboarding::Delivery.request(@user)
        redirect_to verification_status_path, notice: t("auth.registration.created")
      else
        redirect_to verification_status_path, alert: t("auth.registration.delivery_delayed")
      end
    else
      collect_errors
      render :new, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    @user.errors.add(:base, t("auth.registration.errors.already_registered"))
    collect_errors
    render :new, status: :unprocessable_content
  end

  private

  def preview_profile_url
    values = params[:registration]
    return unless values.is_a?(ActionController::Parameters)

    selected = values[:selected_profile_url]
    return selected if selected.is_a?(String) && selected.present?

    values[:directory_profile_url] if values[:directory_profile_url].is_a?(String)
  end

  def name_search_query
    values = params[:registration]
    values[:name_query] if values.is_a?(ActionController::Parameters) && values[:name_query].is_a?(String)
  end

  def name_search_request?
    Directory::AdvocaatBeNameSearch.normalized_query(name_search_query).present?
  end

  def prepare_search_form
    prepare_form(preview_form_attributes.except(:directory_preview_token))
    @name_query = Directory::AdvocaatBeNameSearch.normalized_query(name_search_query).to_s
    @name_search_results = []
    @name_search_truncated = false
  end

  def render_search_failure(error, status:)
    message = t("signup_search.errors.#{error}")
    respond_to do |format|
      format.json { render json: { status: error, message: }, status: }
      format.html do
        prepare_search_form
        @registration_errors << message
        render :new, status:
      end
    end
  end

  def preview_lookup_request?
    Directory::AdvocaatBeProfileLookup.valid_profile_url?(preview_profile_url)
  end

  def preview_form_attributes
    params[:registration].is_a?(ActionController::Parameters) ? registration_params.to_h.symbolize_keys.except(:password, :password_confirmation) : {}
  end

  def render_preview_failure(error, status:)
    message = t("signup_profile.errors.#{error}")
    respond_to do |format|
      format.json { render json: { status: error, message: }, status: }
      format.html do
        attributes = preview_form_attributes
        @terms_accepted = ActiveModel::Type::Boolean.new.cast(attributes[:terms_accepted])
        prepare_form(attributes)
        @registration_errors << message
        render :new, status:
      end
    end
  end

  def prepare_form(attributes = {})
    locale = attributes[:locale].presence_in(User::LOCALES) || I18n.locale.to_s
    @request_alternative_email = ActiveModel::Type::Boolean.new.cast(attributes[:request_alternative_email]) || false
    @directory_identity = Directory::SignupPreview.read(token: attributes[:directory_preview_token], profile_url: attributes[:directory_profile_url])
    email = @directory_identity&.fetch("email_address", nil)

    @user = User.new(
      first_name: @directory_identity&.fetch("first_name", nil),
      last_name: @directory_identity&.fetch("last_name", nil),
      email_address: email,
      password: attributes[:password],
      password_confirmation: attributes[:password_confirmation],
      locale: locale
    )
    @firm = Firm.new(name: Firm::INTERNAL_WORKSPACE_NAME)
    @lawyer_profile = @user.build_lawyer_profile(
      # Existing schema requires a registry value before the official lookup.
      # Keep it opaque so a public directory UUID cannot be squatted at signup.
      bar_association: "OVB",
      bar_number: "PENDING-#{SecureRandom.uuid}",
      professional_email: email,
      directory_profile_url: Directory::AdvocaatBeProfileLookup.canonical_profile_url(attributes[:directory_profile_url]),
      spoken_languages: [ locale.upcase ]
    )
    @form_values = attributes.except(:password, :password_confirmation, :email_address).stringify_keys
    @form_values.delete("directory_preview_token") unless @directory_identity
    @form_values.merge!(@user.attributes.slice("first_name", "last_name"))
    @registration_errors = []
  end

  def persist_registration!
    ApplicationRecord.transaction do
      @user.save!
      @firm.save!
      @user.memberships.create!(firm: @firm, role: "owner")
      @lawyer_profile.save!
      if @lawyer_profile.email_review_pending?
        AuditEvent.create!(auditable: @lawyer_profile, actor_user: @user, firm: @firm,
          action: "email_access.requested", metadata: {})
      end
    end
  end

  def prepare_alternative_email(attributes)
    email = attributes[:alternative_email_address]
    email = email.is_a?(String) ? email.strip.downcase : ""
    @user.email_address = email
    @lawyer_profile.professional_email = email
    return if email == @directory_identity.fetch("email_address")

    @lawyer_profile.assign_attributes(email_review_status: "pending", email_review_email_address: email,
      email_review_requested_at: Time.current)
  end

  def collect_errors
    @registration_errors = [ @user, @firm, @lawyer_profile ].flat_map do |record|
      record.errors.full_messages
    end.uniq
  end

  def registration_params
    params.require(:registration).permit(
      :password, :password_confirmation, :request_alternative_email, :alternative_email_address,
      :directory_profile_url, :directory_preview_token,
      :locale, :terms_accepted
    )
  end
end
