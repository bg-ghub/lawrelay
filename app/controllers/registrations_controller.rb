class RegistrationsController < ApplicationController
  TERMS_VERSION = "2026-10-28"
  PRIVACY_VERSION = "2026-10-28"

  allow_unauthenticated_access
  rate_limit to: 5, within: 1.hour, only: :create,
    with: -> { redirect_to new_registration_path, alert: t("auth.registration.errors.rate_limited") }

  def new
    prepare_form
  end

  def create
    attributes = registration_params.to_h.symbolize_keys
    @terms_accepted = ActiveModel::Type::Boolean.new.cast(attributes.delete(:terms_accepted))
    prepare_form(attributes)

    @user.accepted_terms_at = Time.current if @terms_accepted
    @user.accepted_terms_version = TERMS_VERSION if @terms_accepted
    @user.accepted_privacy_version = PRIVACY_VERSION if @terms_accepted
    models_valid = @user.valid? & @firm.valid? & @lawyer_profile.valid?
    unless Directory::AdvocaatBeProfileLookup.valid_profile_url?(attributes[:directory_profile_url])
      @lawyer_profile.errors.add(:directory_profile_url, t("directory_onboarding.registration.invalid_profile_url"))
      models_valid = false
    end
    @user.errors.add(:base, t("auth.registration.errors.accept_terms")) unless @terms_accepted

    if @terms_accepted && models_valid
      persist_registration!
      start_new_session_for(@user)
      EmailVerificationMailer.verify(@user).deliver_later
      Directory::VerificationJob.perform_later(@user.id)
      redirect_to verification_status_path, notice: t("auth.registration.created")
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

  def prepare_form(attributes = {})
    locale = attributes[:locale].presence_in(User::LOCALES) || I18n.locale.to_s
    email = attributes[:email_address].to_s

    @user = User.new(
      first_name: attributes[:first_name],
      last_name: attributes[:last_name],
      email_address: email,
      password: attributes[:password],
      password_confirmation: attributes[:password_confirmation],
      locale: locale
    )
    @firm = Firm.new(
      name: attributes[:firm_name],
      enterprise_number: attributes[:enterprise_number],
      vat_number: attributes[:vat_number],
      billing_email: email
    )
    @lawyer_profile = @user.build_lawyer_profile(
      # Existing schema requires a registry value before the official lookup.
      # Keep it opaque so a public directory UUID cannot be squatted at signup.
      bar_association: "OVB",
      bar_number: "PENDING-#{SecureRandom.uuid}",
      professional_email: email,
      directory_profile_url: Directory::AdvocaatBeProfileLookup.canonical_profile_url(attributes[:directory_profile_url]),
      spoken_languages: [ locale.upcase ]
    )
    @form_values = attributes.except(:password, :password_confirmation).stringify_keys
    @registration_errors = []
  end

  def persist_registration!
    ApplicationRecord.transaction do
      @user.save!
      @firm.save!
      @user.memberships.create!(firm: @firm, role: "owner")
      @lawyer_profile.save!
    end
  end

  def collect_errors
    @registration_errors = [ @user, @firm, @lawyer_profile ].flat_map do |record|
      record.errors.full_messages
    end.uniq
  end

  def registration_params
    params.require(:registration).permit(
      :first_name, :last_name, :email_address, :password, :password_confirmation,
      :firm_name, :enterprise_number, :vat_number, :directory_profile_url,
      :locale, :terms_accepted
    )
  end
end
