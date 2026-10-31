class BillingController < ApplicationController
  helper_method :billing_checkout_available?

  rate_limit to: 3, within: 1.hour, only: :checkout, by: -> { current_user&.id },
    with: -> { redirect_to billing_path, alert: t("billing.notices.rate_limited") }

  before_action :require_verified_lawyer
  before_action :require_paid_release
  before_action :set_firm_and_account
  before_action :require_firm_administrator, only: %i[checkout cancel]

  def show
    @subscription = @billing_account.current_subscription
    @invoices = @billing_account.invoices.order(created_at: :desc)
  end

  def checkout
    unless billing_checkout_available?
      return redirect_to billing_path, alert: t("billing.notices.payments_unavailable_during_beta")
    end

    result = Billing::ManualInvoiceService.new(billing_account: @billing_account).call
    Billing::ManualPeppolInvoiceService.new(result.invoice).call

    redirect_to billing_path, notice: t("billing.notices.invoice_requested", number: result.invoice.number)
  end

  def cancel
    subscription = @billing_account.current_subscription
    subscription&.cancel!
    @billing_account.update!(status: "cancelled") if subscription

    redirect_to billing_path, notice: t("billing.notices.subscription_cancelled")
  end

  def return
    redirect_to billing_path, notice: t("billing.notices.payment_confirmation_pending")
  end

  private

  def require_paid_release
    redirect_to dashboard_path unless billing_checkout_available?
  end

  def set_firm_and_account
    @firm = Current.user&.primary_firm
    redirect_to root_path, alert: t("billing.notices.no_firm") and return unless @firm

    @billing_account = BillingAccount.find_or_create_by!(firm: @firm) do |account|
      account.plan_key = "founding_beta"
      account.status = "pending"
    end
  end

  def require_firm_administrator
    return if Current.user&.firm_administrator?(@firm)

    redirect_to billing_path, alert: t("billing.notices.administrator_required")
  end

  def billing_checkout_available?
    ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
  end
end
