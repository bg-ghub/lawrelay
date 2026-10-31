module Admin
  class EmailReviewsController < BaseController
    before_action :set_user, except: :index
    before_action -> { response.headers["Cache-Control"] = "no-store" }

    def index
      @users = User.where(system_role: "member", erased_at: nil).joins(:lawyer_profile)
        .where(lawyer_profiles: { email_review_status: "pending" }).includes(:lawyer_profile, memberships: :firm)
        .order("lawyer_profiles.email_review_requested_at ASC", "users.id ASC")
    end

    def show
    end

    def update
      result = Accounts::ReviewEmailAccess.call(user: @user, actor: current_user, decision: params[:decision],
        note: review_params[:note], identity_checked: review_params[:identity_checked], identity_digest: review_params[:identity_digest])
      unless result.success?
        @errors = result.errors
        @user.reload
        load_details
        return render :show, status: :unprocessable_content
      end

      queued = Onboarding::Delivery.enqueue { EmailAccessReviewDeliveryJob.perform_later(result.profile.id, result.profile.email_reviewed_at.utc.iso8601(6)) }
      redirect_to admin_email_review_path(@user), notice: t("email_access.notices.#{result.profile.email_review_status}"),
        alert: (t("auth.verification_status.queue_unavailable") unless queued)
    end

    private

    def set_user
      scope = User.where(system_role: "member", erased_at: nil).joins(:lawyer_profile)
        .where.not(lawyer_profiles: { email_review_status: nil }).includes(:lawyer_profile, memberships: :firm)
      @user = find_user_resource!(scope)
      return if redirect_legacy_user_resource(@user, admin_email_review_path(@user))

      load_details
    end

    def load_details
      @profile = @user.lawyer_profile
      @firm = @user.primary_firm
    end

    def review_params
      params.fetch(:email_review, {}).permit(:note, :identity_checked, :identity_digest)
    end
  end
end
