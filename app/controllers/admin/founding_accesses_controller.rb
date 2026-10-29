module Admin
  class FoundingAccessesController < BaseController
    before_action :require_paid_release
    before_action :set_firm, only: %i[create destroy]

    def index
      @firms = Firm.where(verification_status: "verified")
        .includes(:billing_account, :users)
        .order(:name)
    end

    def create
      Billing::FoundingAccessService.new.grant!(
        firm: @firm,
        expires_on: expiry_date,
        actor: current_user
      )
      redirect_to admin_founding_accesses_path,
        notice: t("admin.founding_accesses.notices.granted", name: @firm.name)
    rescue Date::Error, ArgumentError, Billing::FoundingAccessService::InvalidExpiry
      redirect_to admin_founding_accesses_path,
        alert: t("admin.founding_accesses.notices.invalid_expiry")
    rescue Billing::FoundingAccessService::IneligibleFirm
      redirect_to admin_founding_accesses_path,
        alert: t("admin.founding_accesses.notices.unverified_firm")
    rescue Billing::FoundingAccessService::PaidAccount
      redirect_to admin_founding_accesses_path,
        alert: t("admin.founding_accesses.notices.paid_account")
    end

    def destroy
      Billing::FoundingAccessService.new.revoke!(firm: @firm, actor: current_user)
      redirect_to admin_founding_accesses_path,
        notice: t("admin.founding_accesses.notices.revoked", name: @firm.name)
    end

    private

    def require_paid_release
      redirect_to admin_users_path unless ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
    end

    def set_firm
      @firm = Firm.find(params[:firm_id])
    end

    def expiry_date
      Date.iso8601(params.dig(:founding_access, :expires_on).to_s)
    end
  end
end
