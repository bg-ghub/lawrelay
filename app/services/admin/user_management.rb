module Admin
  class UserManagement
    EDITABLE_ATTRIBUTES = %w[first_name last_name email_address locale].freeze
    IDENTITY_ATTRIBUTES = %w[first_name last_name email_address].freeze
    Result = Data.define(:changed, :identity_changed, :email_changed)

    class InvalidAction < StandardError
      attr_reader :translation_key

      def initialize(key)
        @translation_key = "admin.users.errors.#{key}"
        super(@translation_key)
      end
    end

    def initialize(actor:, user:)
      @actor = actor
      @user = user
    end

    def update!(attributes)
      result = Result.new(changed: false, identity_changed: false, email_changed: false)
      with_managed_user do
        @user.assign_attributes(attributes.stringify_keys.slice(*EDITABLE_ATTRIBUTES))
        changed_fields = @user.changes_to_save.keys & EDITABLE_ATTRIBUTES
        next if changed_fields.empty?

        identity_changed = changed_fields.intersect?(IDENTITY_ATTRIBUTES)
        email_changed = changed_fields.include?("email_address")
        profile = @user.lawyer_profile
        if identity_changed && profile
          profile.with_lock do
            clear_directory_evidence!(profile)
            @user.save!
            profile.save!
          end
        else
          @user.save!
        end
        @user.sessions.destroy_all if identity_changed
        audit!("admin.user_updated", changed_fields: changed_fields, identity_reverification: identity_changed)
        result = Result.new(changed: true, identity_changed:, email_changed:)
      end
      result
    end

    def suspend!(reason:)
      with_managed_user do
        reason = checked_reason(reason)
        next false if @user.suspended?

        @user.update!(suspended_at: Time.current, suspension_reason: reason)
        @user.sessions.destroy_all
        audit!("admin.user_suspended", reason:)
        true
      end
    end

    def restore!(reason:)
      with_managed_user do
        reason = checked_reason(reason)
        next false if @user.active?

        @user.update!(suspended_at: nil, suspension_reason: nil)
        @user.sessions.destroy_all
        audit!("admin.user_restored", reason:)
        true
      end
    end

    def revoke_sessions!(reason:)
      with_managed_user do
        reason = checked_reason(reason)
        count = @user.sessions.count
        next false if count.zero?

        @user.sessions.destroy_all
        audit!("admin.user_sessions_revoked", reason:, session_count: count)
        true
      end
    end

    private

    def with_managed_user
      raise InvalidAction, :protected_account unless @actor&.system_admin? && @actor.active?

      @user.with_lock do
        raise InvalidAction, :protected_account if @user.system_admin? || @user.id == @actor.id

        yield
      end
    end

    def checked_reason(value)
      reason = value.to_s.strip
      raise InvalidAction, :reason_required if reason.blank?
      raise InvalidAction, :reason_too_long if reason.length > 2_000

      reason
    end

    def clear_directory_evidence!(profile)
      profile.assign_attributes(
        directory_profile_id: nil, directory_name: nil, directory_email: nil,
        directory_checked_at: nil, directory_email_verified_at: nil,
        directory_confirmation_requested_at: nil, directory_identity_digest: nil
      )
      unless profile.verification_status.in?(%w[rejected suspended])
        profile.assign_attributes(verification_status: "pending", verified_at: nil, verification_note: nil)
      end
    end

    def audit!(action, metadata)
      AuditEvent.create!(auditable: @user, actor_user: @actor, firm: @user.primary_firm, action:, metadata:)
    end
  end
end
