module Admin
  class MfaController < ApplicationController
    before_action -> { response.headers["Cache-Control"] = "no-store" }
    rate_limit to: 5, within: 3.minutes, only: %i[confirm_setup verify], by: -> { current_user&.id },
      with: -> { redirect_to admin_mfa_challenge_path, alert: t("mfa.notices.rate_limited") }

    before_action :require_system_admin
    before_action :redirect_verified_session
    before_action :require_initial_setup, only: %i[setup confirm_setup]

    def setup
      @secret = current_user.begin_admin_mfa_setup!
      @provisioning_uri = current_user.admin_mfa_provisioning_uri(@secret)
      @qr_code = RQRCode::QRCode.new(@provisioning_uri, level: :m)
        .as_png(module_px_size: 6, border_modules: 4).to_data_url
    rescue User::InvalidAdminMfaCode
      redirect_to admin_mfa_challenge_path
    end

    def confirm_setup
      verified_at = current_user.enable_admin_mfa!(mfa_code)
      Current.session.mark_admin_mfa_verified!(at: verified_at)
      record_audit_event("admin.mfa_enabled")
      redirect_to after_admin_mfa_url, notice: t("mfa.notices.enabled")
    rescue User::InvalidAdminMfaCode
      return redirect_to admin_mfa_challenge_path if current_user.reload.admin_mfa_configured?

      setup
      return if performed?

      flash.now[:alert] = t("mfa.notices.invalid_code")
      render :setup, status: :unprocessable_content
    end

    def challenge
      redirect_to admin_mfa_setup_path unless current_user.admin_mfa_configured?
    end

    def verify
      if current_user.admin_mfa_configured?
        verified_at = current_user.verify_admin_mfa_code!(mfa_code)
        Current.session.mark_admin_mfa_verified!(at: verified_at)
        record_audit_event("admin.mfa_challenged")
        redirect_to after_admin_mfa_url, notice: t("mfa.notices.verified")
      else
        redirect_to admin_mfa_setup_path
      end
    rescue User::InvalidAdminMfaCode
      flash.now[:alert] = t("mfa.notices.invalid_code")
      render :challenge, status: :unprocessable_content
    end

    private

    def mfa_code
      params[:mfa_code]
    end

    def require_initial_setup
      redirect_to admin_mfa_challenge_path if current_user.admin_mfa_configured?
    end

    def redirect_verified_session
      return unless Current.session&.admin_mfa_verified?

      redirect_to after_admin_mfa_url
    end

    def after_admin_mfa_url
      session.delete(:return_to_after_admin_mfa) || admin_verifications_path
    end

    def record_audit_event(action)
      AuditEvent.create!(
        auditable: current_user,
        actor_user: current_user,
        firm: current_user.primary_firm,
        action: action,
        metadata: { session_id: Current.session.id }
      )
    end
  end
end
