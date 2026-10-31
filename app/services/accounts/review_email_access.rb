module Accounts
  class ReviewEmailAccess
    Result = Data.define(:success?, :user, :profile, :errors)

    def self.call(user:, actor:, decision:, note:, identity_checked:, identity_digest:)
      new(user:, actor:, decision:, note:, identity_checked:, identity_digest:).call
    end

    def initialize(user:, actor:, decision:, note:, identity_checked:, identity_digest:)
      @user, @actor, @decision = user, actor, decision.to_s
      @note = note.to_s.strip
      @identity_checked = ActiveModel::Type::Boolean.new.cast(identity_checked)
      @identity_digest = identity_digest.to_s
    end

    def call
      user = profile = nil
      return failure(@user, nil, :protected) unless @actor

      ApplicationRecord.transaction do
        actor = User.lock.find(@actor.id)
        return failure(@user, nil, :protected) unless actor.system_admin? && actor.active? && actor.admin_mfa_configured?
        user = User.lock.find(@user.id)
        profile = LawyerProfile.lock.find_by(user_id: user.id)
        firm = user.primary_firm
        firm&.lock!
        return failure(user, profile, :protected) unless user.active? && !user.system_admin?
        return failure(user, profile, :incomplete) unless profile && firm
        return failure(user, profile, :protected) if [ profile, firm ].any? { |record| record.verification_status.in?(%w[rejected suspended]) }
        return failure(user, profile, :invalid_decision) unless @decision.in?(%w[approve reject])
        return failure(user, profile, :already_reviewed) unless profile.email_review_pending?
        return failure(user, profile, :stale) unless profile.email_review_email_address == user.email_address &&
          @identity_digest.present? && @identity_digest == profile.email_review_current_identity_digest
        return failure(user, profile, :note_required) if @note.blank? || @note.length > 2_000
        if @decision == "approve"
          return failure(user, profile, :email_unconfirmed) unless user.email_verified?
          return failure(user, profile, :identity_required) unless @identity_checked
          return failure(user, profile, :directory_required) unless profile.email_review_directory_ready?
          claimed = LawyerProfile.where.not(id: profile.id).where(directory_profile_id: profile.directory_profile_id)
            .where("directory_email_verified_at IS NOT NULL OR email_review_status = ? OR manual_activation_approved_at IS NOT NULL", "approved").exists?
          return failure(user, profile, :claimed) if claimed
        end

        status = @decision == "approve" ? "approved" : "rejected"
        profile.update!(email_review_status: status, email_reviewed_at: Time.current, email_reviewed_by_user: actor,
          email_review_note: @note, email_review_identity_digest: @identity_digest)
        AuditEvent.create!(auditable: profile, actor_user: actor, firm: firm,
          action: "email_access.#{status}", metadata: { note: @note })
        if status == "approved"
          Directory::Verification.activate_if_ready!(user:)
          profile.reload
        end
      end
      Result.new(true, user, profile, [])
    rescue ActiveRecord::RecordNotUnique
      failure(user || @user, profile, :claimed)
    rescue ActiveRecord::RecordInvalid => error
      Result.new(false, user || @user, profile, error.record.errors.full_messages)
    rescue ActiveRecord::RecordNotFound
      failure(@user, nil, :unavailable)
    end

    private

    def failure(user, profile, key)
      Result.new(false, user, profile, [ I18n.t("email_access.errors.#{key}") ])
    end
  end
end
