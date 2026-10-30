class AccountDeletionsController < ApplicationController
  before_action :require_member
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  rate_limit to: 3, within: 1.hour, only: :destroy, by: -> { current_user.id },
    with: -> { redirect_to account_deletion_path, alert: t("account_deletion.notices.rate_limited") }

  def show
  end

  def destroy
    unless confirmed?
      flash.now[:alert] = t("account_deletion.notices.confirmation_required")
      return render :show, status: :unprocessable_content
    end

    unless current_user.authenticate(params[:current_password].to_s)
      flash.now[:alert] = t("account_deletion.notices.invalid_password")
      return render :show, status: :unprocessable_content
    end

    request_record = current_user.privacy_requests.create!(
      kind: "deletion", details: t("account_deletion.request_details")
    )
    request_record.audit_events.create!(
      actor_user: current_user, firm: current_firm, action: "privacy_request.created",
      metadata: { kind: "deletion", self_service: true }
    )
    erase_account!(request_record)
    sign_out_erased_member
    redirect_to root_path, notice: t("account_deletion.notices.deleted"), status: :see_other
  rescue Privacy::AccountErasure::ProtectedAccount => error
    discard_pending_request!(request_record)
    flash.now[:alert] = protection_message(error)
    render :show, status: :unprocessable_content
  rescue Privacy::ErasureLedger::UnsafeLedger => error
    return completed_erasure_with_pending_ledger(request_record, error) if erased?(request_record)

    discard_pending_request!(request_record)
    flash.now[:alert] = t("account_deletion.notices.unavailable")
    render :show, status: :service_unavailable
  rescue Privacy::RequestContext::InvalidRequest
    discard_pending_request!(request_record)
    flash.now[:alert] = t("account_deletion.notices.unavailable")
    render :show, status: :service_unavailable
  end

  private

  def require_member
    return unless current_user.system_admin?

    head :forbidden
  end

  def confirmed?
    params[:confirm_delete_account] == "1"
  end

  def erase_account!(request_record)
    Privacy::AccountErasure.new(request: request_record, actor: current_user, ledger: erasure_ledger, self_service: true).call
  end

  def erasure_ledger
    Privacy::ErasureLedger.new
  end

  def sign_out_erased_member
    Current.session = nil
    cookies.delete(:session_id)
    reset_session
  end

  def completed_erasure_with_pending_ledger(request_record, error)
    Rails.logger.warn("Account erasure completed before ledger finalization: #{error.class}")
    sign_out_erased_member
    redirect_to root_path, notice: t("account_deletion.notices.deleted"), status: :see_other
  end

  def erased?(request_record)
    request_record && User.where(id: request_record.user_id).where.not(erased_at: nil).exists?
  end

  def discard_pending_request!(request_record)
    return unless request_record

    request = PrivacyRequest.find_by(id: request_record.id, user_id: current_user.id, kind: "deletion", status: "pending", handled_by_user_id: nil)
    request&.destroy!
  end

  def protection_message(error)
    return t("account_deletion.notices.open_work") if error.message.include?("ongoing assignments and proposals")
    return t("account_deletion.notices.held") if error.message.include?("hold")
    return t("account_deletion.notices.billing") if error.message.include?("billing evidence")

    t("account_deletion.notices.blocked")
  end
end
