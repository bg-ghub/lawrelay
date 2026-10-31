module Admin
  class VerificationDelivery
    CHANNELS = %w[account_email directory_email].freeze

    def initialize(actor:, user:)
      @actor = actor
      @user = user
    end

    def eligible?
      return false unless @actor&.system_admin? && @actor.active?
      return false unless @user.active? && !@user.system_admin? && @user.id != @actor.id
      return false if profile&.verification_status.in?(%w[rejected suspended]) || profile&.email_review_status == "rejected"
      return false if @user.primary_firm&.verification_status.in?(%w[rejected suspended])

      @user.email_verification_required? || profile&.directory_confirmation_required? || false
    end

    def directory_check_pending?
      !profile&.directory_matched?
    end

    def request
      @user.reload
      return :ineligible unless eligible?

      channels = []
      email_needed = @user.email_verification_required?
      directory_needed = profile&.directory_confirmation_required?
      email_ready = !email_needed || Onboarding::Delivery.request(@user, directory: false)
      channels << "account_email" if email_needed && email_ready
      directory_ready = !directory_needed || Onboarding::Delivery.enqueue { Directory::ConfirmationJob.perform_later(profile.id) }
      channels << "directory_email" if directory_needed && directory_ready

      if channels.any?
        AuditEvent.create!(auditable: @user, actor_user: @actor, firm: @user.primary_firm,
          action: "user.verification_resent", metadata: { channels: channels & CHANNELS })
      end

      email_ready && directory_ready ? :queued : :unavailable
    end

    private

    def profile
      @user.lawyer_profile
    end
  end
end
