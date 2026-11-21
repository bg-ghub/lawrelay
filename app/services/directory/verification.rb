require "digest"

module Directory
  class Verification
    class ConfirmationUnavailable < StandardError; end

    Result = Data.define(:status, :profile) do
      def success? = status == :matched || status == :activated
    end

    def self.request!(user:, directory_profile_url: nil, lookup: AdvocaatBeProfileLookup)
      new(user, lookup:).request!(directory_profile_url:)
    end

    def self.activate_if_ready!(user:, actor: nil)
      new(user, actor:).activate_if_ready!
    end

    def self.confirm!(profile)
      new(profile.user).confirm!(profile)
    end

    def initialize(user, lookup: AdvocaatBeProfileLookup, actor: nil)
      @user = user
      @profile = user.lawyer_profile
      @lookup = lookup
      @actor = actor || user
    end

    def request!(directory_profile_url: nil)
      return Result.new(status: :protected, profile: @profile) unless @user.active?
      return Result.new(status: :missing_profile, profile: nil) unless @profile
      @profile.update!(directory_profile_url:) if directory_profile_url.present? && !@profile.directory_matched?
      stored_url = @profile.directory_profile_url
      requested_url = directory_profile_url.presence || stored_url
      requested_name = @user.full_name
      evidence = @lookup.call(profile_url: requested_url, full_name: requested_name)
      unless evidence.success?
        record_lookup_failure(evidence.status, requested_url:, requested_name:)
        return Result.new(status: evidence.status, profile: @profile)
      end
      ApplicationRecord.transaction do
        @user.lock!
        @profile.lock!
        return Result.new(status: :protected, profile: @profile) unless @user.active?
        return Result.new(status: :stale, profile: @profile) unless @profile.directory_profile_url == stored_url && @user.full_name == requested_name
        ids = [ evidence.original_profile_id, evidence.profile_id ].uniq
        raise ProfileLinks::Conflict if ProfileLinks.claimed_by_other?(profile: @profile, profile_ids: ids)
        moved = ids.size > 1 || (@profile.directory_matched? && evidence.profile_id != @profile.directory_profile_id)
        if moved && @profile.directory_email.present? &&
            (!same_email?(@profile.directory_email, evidence.email) || !AdvocaatBeProfileLookup.names_match?(@profile.directory_name, evidence.name))
          return Result.new(status: :identity_mismatch, profile: @profile)
        end
        if moved && @profile.directory_matched?
          source_owned = @profile.directory_profile_id == evidence.original_profile_id ||
            DirectoryProfileLink.exists?(lawyer_profile: @profile, directory_profile_id: evidence.original_profile_id)
          return Result.new(status: :identity_mismatch, profile: @profile) unless source_owned
          # The official redirect identifies another URL for the same lawyer.
          # Keep the original identity covered by approvals and email tokens.
          ProfileLinks.register!(profile: @profile, profile_ids: ids)
          @profile.update!(directory_checked_at: evidence.checked_at)
          next
        end
        ProfileLinks.register!(profile: @profile, profile_ids: ids) if ids.size > 1

        @profile.assign_attributes(
          directory_profile_id: evidence.profile_id, directory_profile_url: evidence.source_url,
          directory_name: evidence.name, directory_email: evidence.email, directory_checked_at: evidence.checked_at,
          directory_email_verified_at: (@user.email_verified? && same_email?(@user.email_address, evidence.email) ? Time.current : nil),
          directory_confirmation_requested_at: nil,
          directory_identity_digest: identity_digest(evidence)
        )
        @profile.invalidate_changed_email_review
        @profile.save!
        audit!("verification.directory_matched", profile_id: @profile.id, directory_profile_id: evidence.profile_id)
      end
      activate_if_ready!
      Result.new(status: :matched, profile: @profile)
    rescue ProfileLinks::Conflict
      record_lookup_failure(:already_claimed, requested_url:, requested_name:)
      Result.new(status: :already_claimed, profile: @profile)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      return Result.new(status: :already_claimed, profile: @profile) if error.message.include?("directory_profile_id")

      raise
    end

    def confirm!(profile = @profile)
      return Result.new(status: :invalid, profile:) unless profile == @profile && profile.directory_matched?

      ApplicationRecord.transaction do
        @user.lock!
        profile.lock!
        return Result.new(status: :protected, profile:) unless @user.active?
        return Result.new(status: :invalid, profile:) unless identity_current?(profile)
        return Result.new(status: :already_claimed, profile:) if ProfileLinks.claimed_by_other?(profile:, profile_ids: [ profile.directory_profile_id ])
        unless profile.directory_email_verified?
          profile.update!(directory_email_verified_at: Time.current)
          audit!("verification.directory_email_confirmed", profile_id: profile.id, directory_profile_id: profile.directory_profile_id)
        end
      end
      activate_if_ready! unless @user.reload.marketplace_verified?
      Result.new(status: :confirmed, profile:)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      return Result.new(status: :already_claimed, profile:) if error.message.include?("directory_profile_id")

      raise
    end

    def activate_if_ready!
      return Result.new(status: :protected, profile: @profile) unless @user.active?
      return Result.new(status: :pending, profile: @profile) unless @profile
      firm = @user.primary_firm
      return Result.new(status: :pending, profile: @profile) unless firm
      return Result.new(status: :protected, profile: @profile) if protected?(@profile) || protected?(firm)

      ApplicationRecord.transaction do
        @user.lock!
        @profile.lock!
        firm.lock!
        return Result.new(status: :protected, profile: @profile) unless @user.active?
        return Result.new(status: :protected, profile: @profile) if protected?(@profile) || protected?(firm)
        return Result.new(status: :pending, profile: @profile) unless identity_current?(@profile)
        return Result.new(status: :already_claimed, profile: @profile) if ProfileLinks.claimed_by_other?(profile: @profile, profile_ids: [ @profile.directory_profile_id ])
        return Result.new(status: :pending, profile: @profile) unless @profile.email_review_allows_access?
        return Result.new(status: :pending, profile: @profile) unless same_email?(@user.email_address, @profile.directory_email) || @profile.email_review_approved?
        if @user.email_verified? && !@profile.directory_email_verified? && same_email?(@user.email_address, @profile.directory_email)
          @profile.update!(directory_email_verified_at: Time.current)
        end
        return Result.new(status: :protected, profile: @profile) if protected?(@profile) || protected?(firm)
        manually_approved = @profile.manual_activation_valid?
        return Result.new(status: :pending, profile: @profile) unless @profile.directory_matched? && (@user.email_verified? || manually_approved) &&
          (@profile.directory_email_verified? || @profile.email_review_approved? || manually_approved)
        @profile.update!(verification_status: "verified", verified_at: Time.current) unless @profile.verified?
        firm.update!(verification_status: "verified", verified_at: Time.current) unless firm.verified?
        audit!("verification.directory_activated", profile_id: @profile.id, firm_id: firm.id, directory_profile_id: @profile.directory_profile_id)
      end
      Result.new(status: :activated, profile: @profile)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      return Result.new(status: :already_claimed, profile: @profile) if error.message.include?("directory_profile_id")

      raise
    end

    private

    def record_lookup_failure(status, requested_url:, requested_name:)
      code = status.to_s
      return unless LawyerProfile::DIRECTORY_LOOKUP_FAILURES.include?(code)

      ApplicationRecord.transaction do
        @user.lock!
        @profile.lock!
        next unless @user.active? && @profile.verification_status == "pending"
        next if @user.primary_firm && protected?(@user.primary_firm)
        next unless @profile.directory_profile_url == requested_url && @user.full_name == requested_name

        audit!("verification.directory_lookup_failed", status: code,
          identity_digest: @profile.directory_lookup_identity_digest(full_name: requested_name, profile_url: requested_url))
      end
    end

    def same_email?(first, second)
      first.to_s.casecmp?(second.to_s)
    end

    def protected?(record)
      record.verification_status.in?(%w[suspended rejected])
    end

    def identity_digest(evidence)
      Digest::SHA256.hexdigest([ @profile.id, evidence.profile_id, evidence.source_url, evidence.name, evidence.email, evidence.checked_at.to_i ].join("\u0000"))
    end

    def identity_current?(profile)
      profile.directory_matched? && AdvocaatBeProfileLookup.names_match?(profile.directory_name, @user.full_name)
    end

    def audit!(action, metadata)
      AuditEvent.create!(actor_user: @actor, firm: @user.primary_firm, auditable: @profile, action:, metadata:)
    end
  end
end
