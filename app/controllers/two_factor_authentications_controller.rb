class TwoFactorAuthenticationsController < ApplicationController
  SETUP_LIFETIME = 10.minutes
  class RevokedSession < StandardError; end

  rescue_from RevokedSession, with: :reject_revoked_session

  before_action -> { response.headers["Cache-Control"] = "no-store" }
  before_action :require_member

  rate_limit to: 5, within: 3.minutes, name: "account", by: -> { current_user.id },
    only: %i[begin_setup enable verify destroy], with: :rate_limited
  rate_limit to: 20, within: 3.minutes, name: "ip",
    only: %i[begin_setup enable verify destroy], with: :rate_limited

  def show
  end

  def begin_setup
    with_current_member_session do
      current_user.begin_two_factor_setup!(password: params[:current_password])
      session[:two_factor_setup] = {
        "user_id" => current_user.id, "session_id" => Current.session.id,
        "authorized_at" => Time.current.to_i
      }
    end
    redirect_to setup_two_factor_authentication_path
  rescue User::InvalidTwoFactorPassword
    flash.now[:alert] = t("two_factor.notices.invalid_password")
    render :show, status: :unprocessable_content
  rescue User::InvalidTwoFactorCode
    redirect_to two_factor_authentication_path
  end

  def setup
    with_current_member_session do
      require_setup_authorization
      load_setup unless performed?
    end
  end

  def enable
    with_current_member_session do
      require_setup_authorization
      next if performed?

      @recovery_codes = current_user.enable_two_factor!(params[:mfa_code])
      rotate_session!(revoke_all: true, verified: true)
      record_audit_event("account.two_factor_enabled")
    end
    return if performed?

    session.delete(:two_factor_setup)
    flash.now[:notice] = t("two_factor.notices.enabled")
    render :recovery_codes
  rescue User::InvalidTwoFactorCode
    return redirect_to two_factor_authentication_path if current_user.reload.two_factor_enabled?

    load_setup
    return if performed?

    flash.now[:alert] = t("two_factor.notices.invalid_code")
    render :setup, status: :unprocessable_content
  end

  def challenge
    redirect_to after_two_factor_url if !current_user.two_factor_enabled? || Current.session.two_factor_verified?
  end

  def verify
    return redirect_to two_factor_authentication_path unless current_user.two_factor_enabled?

    with_current_member_session do
      current_user.verify_two_factor_code!(code: params[:mfa_code], recovery_code: params[:recovery_code])
      rotate_session!(revoke_all: false, verified: true)
      record_audit_event("account.two_factor_verified")
    end
    redirect_to after_two_factor_url, notice: t("two_factor.notices.verified")
  rescue User::InvalidTwoFactorCode
    flash.now[:alert] = t("two_factor.notices.invalid_code")
    render :challenge, status: :unprocessable_content
  end

  def destroy
    with_current_member_session do
      current_user.disable_two_factor!(password: params[:current_password], code: params[:mfa_code], recovery_code: params[:recovery_code])
      rotate_session!(revoke_all: true, verified: false)
      record_audit_event("account.two_factor_disabled")
    end
    session.delete(:two_factor_setup)
    redirect_to two_factor_authentication_path, notice: t("two_factor.notices.disabled"), status: :see_other
  rescue User::InvalidTwoFactorPassword, User::InvalidTwoFactorCode => error
    key = error.is_a?(User::InvalidTwoFactorPassword) ? "invalid_password" : "invalid_code"
    flash.now[:alert] = t("two_factor.notices.#{key}")
    render :show, status: :unprocessable_content
  end

  private

  def require_member
    redirect_to settings_path if current_user.system_admin?
  end

  def with_current_member_session
    user = current_user
    session_id = Current.session.id
    user.with_lock do
      active_session = user.sessions.lock.find_by(id: session_id)
      raise RevokedSession unless user.active? && !user.system_admin? && active_session && !active_session.expired?

      active_session.user = user
      Current.session = active_session
      yield
    end
  end

  def reject_revoked_session
    session.delete(:two_factor_setup)
    Current.session = nil
    cookies.delete(:session_id)
    locale = params[:locale].presence_in(I18n.available_locales.map(&:to_s)) || I18n.default_locale
    I18n.with_locale(locale) { request_authentication }
  end

  def rotate_session!(revoke_all:, verified:)
    user = current_user
    revoke_all ? user.sessions.destroy_all : Current.session.destroy!
    start_new_session_for(user)
    Current.session.mark_two_factor_verified! if verified
  end

  def require_setup_authorization
    return redirect_to two_factor_authentication_path if current_user.two_factor_enabled?

    authorization = session[:two_factor_setup]
    age = Time.current.to_i - authorization.to_h.fetch("authorized_at", 0).to_i
    authorized = authorization.to_h["user_id"] == current_user.id &&
      authorization.to_h["session_id"] == Current.session.id && age.between?(0, SETUP_LIFETIME.to_i)
    return if authorized && current_user.two_factor_pending_secret.present?

    session.delete(:two_factor_setup)
    redirect_to two_factor_authentication_path, alert: t("two_factor.notices.setup_expired")
  end

  def load_setup
    @secret = current_user.two_factor_pending_secret
    @provisioning_uri = current_user.two_factor_provisioning_uri(@secret)
    @qr_code = RQRCode::QRCode.new(@provisioning_uri, level: :m)
      .as_png(module_px_size: 6, border_modules: 4).to_data_url
  end

  def after_two_factor_url
    url_from(session.delete(:return_to_after_two_factor)) || dashboard_path
  end

  def rate_limited
    destination = current_user.two_factor_enabled? ? challenge_two_factor_authentication_path : two_factor_authentication_path
    redirect_to destination, alert: t("two_factor.notices.rate_limited")
  end

  def record_audit_event(action)
    AuditEvent.create!(auditable: current_user, actor_user: current_user, firm: current_user.primary_firm,
      action:, metadata: { session_id: Current.session.id })
  end
end
