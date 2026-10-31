module Admin
  class ManualActivation
    class ActivationUnavailable < StandardError; end

    Result = Data.define(:status, :user, :profile) do
      def success? = status == :activated
    end

    def self.call(user:, actor:, note:, identity_digest:)
      new(user:, actor:, note:, identity_digest:).call
    end

    def initialize(user:, actor:, note:, identity_digest:)
      @user, @actor = user, actor
      @note = note.to_s.strip
      @identity_digest = identity_digest.to_s
    end

    def call
      user = profile = nil
      return failure(:protected) unless @actor

      ApplicationRecord.transaction do
        actor = User.lock.find(@actor.id)
        return failure(:protected) unless actor.system_admin? && actor.active? && actor.admin_mfa_configured?

        user = User.lock.find(@user.id)
        profile = LawyerProfile.lock.find_by(user_id: user.id)
        firm = user.primary_firm
        firm&.lock!
        return failure(:protected, user, profile) unless user.active? && !user.system_admin?
        return failure(:incomplete, user, profile) unless profile && firm
        return failure(:protected, user, profile) if [ profile, firm ].any? { |record| record.verification_status.in?(%w[rejected suspended]) }
        return failure(:note_required, user, profile) if @note.blank? || @note.length > 2_000
        return failure(:stale, user, profile) unless @identity_digest.present? && @identity_digest == profile.email_review_current_identity_digest
        return failure(:review_required, user, profile) unless profile.email_review_allows_access?
        unless profile.directory_matched? && Directory::AdvocaatBeProfileLookup.valid_profile_url?(profile.directory_profile_url) &&
            Directory::AdvocaatBeProfileLookup.names_match?(profile.directory_name, user.full_name) &&
            profile.directory_email.to_s.casecmp?(user.email_address.to_s)
          return failure(:directory_required, user, profile)
        end
        if LawyerProfile.where.not(id: profile.id).where(directory_profile_id: profile.directory_profile_id)
            .where("directory_email_verified_at IS NOT NULL OR email_review_status = ? OR manual_activation_approved_at IS NOT NULL", "approved").exists?
          return failure(:claimed, user, profile)
        end
        return Result.new(status: :activated, user:, profile:) if profile.manual_activation_valid? && user.marketplace_verified?

        profile.update!(manual_activation_approved_at: Time.current, manual_activation_approved_by_user: actor,
          manual_activation_identity_digest: @identity_digest, verification_note: @note)
        activation = Directory::Verification.activate_if_ready!(user:, actor:)
        raise ActivationUnavailable unless activation.status == :activated && user.reload.marketplace_verified?

        AuditEvent.create!(auditable: profile, actor_user: actor, firm:, action: "verification.approved",
          metadata: { method: "manual_activation", reviewed_user_id: user.id, note: @note,
            email_link_confirmed: false, email_sent: false })
      end
      Result.new(status: :activated, user:, profile: profile.reload)
    rescue ActiveRecord::RecordNotUnique
      failure(:claimed, user || @user, profile)
    rescue ActiveRecord::RecordNotFound
      failure(:unavailable, user || @user, profile)
    rescue ActivationUnavailable
      failure(:unavailable, user || @user, profile&.reload)
    end

    private

    def failure(status, user = @user, profile = nil)
      Result.new(status:, user:, profile:)
    end
  end
end
