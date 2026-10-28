require "digest"

module Directory
  class Verification
    Result = Data.define(:status, :profile) do
      def success? = status == :matched || status == :activated
    end

    def self.request!(user:, directory_profile_url: nil, lookup: AdvocaatBeProfileLookup)
      new(user, lookup:).request!(directory_profile_url:)
    end

    def self.activate_if_ready!(user:)
      new(user).activate_if_ready!
    end

    def self.confirm!(profile)
      new(profile.user).confirm!(profile)
    end

    def initialize(user, lookup: AdvocaatBeProfileLookup)
      @user = user
      @profile = user.lawyer_profile
      @lookup = lookup
    end

    def request!(directory_profile_url: nil)
      return Result.new(status: :missing_profile, profile: nil) unless @profile
      @profile.update!(directory_profile_url:) if directory_profile_url.present?
      requested_url = @profile.directory_profile_url
      requested_name = @user.full_name
      evidence = @lookup.call(profile_url: requested_url, full_name: requested_name)
      return Result.new(status: evidence.status, profile: @profile) unless evidence.success?
      return Result.new(status: :already_claimed, profile: @profile) if LawyerProfile.where.not(id: @profile.id)
        .where(directory_profile_id: evidence.profile_id).where.not(directory_email_verified_at: nil).exists?

      ApplicationRecord.transaction do
        @user.lock!
        @profile.lock!
        return Result.new(status: :stale, profile: @profile) unless @profile.directory_profile_url == requested_url && @user.full_name == requested_name

        @profile.update!(
          directory_profile_id: evidence.profile_id, directory_profile_url: evidence.source_url,
          directory_name: evidence.name, directory_email: evidence.email, directory_checked_at: evidence.checked_at,
          directory_email_verified_at: (@user.email_verified? && same_email?(@user.email_address, evidence.email) ? Time.current : nil),
          directory_confirmation_requested_at: nil,
          directory_identity_digest: identity_digest(evidence)
        )
        audit!("verification.directory_matched", profile_id: @profile.id, directory_profile_id: evidence.profile_id)
      end
      ConfirmationJob.perform_later(@profile.id) if @profile.directory_confirmation_required?
      activate_if_ready!
      Result.new(status: :matched, profile: @profile)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      return Result.new(status: :already_claimed, profile: @profile) if error.message.include?("directory_profile_id")

      raise
    end

    def confirm!(profile = @profile)
      return Result.new(status: :invalid, profile:) unless profile == @profile && profile.directory_matched?

      ApplicationRecord.transaction do
        @user.lock!
        profile.lock!
        return Result.new(status: :invalid, profile:) unless identity_current?(profile)

        profile.update!(directory_email_verified_at: Time.current)
        audit!("verification.directory_email_confirmed", profile_id: profile.id, directory_profile_id: profile.directory_profile_id)
      end
      activate_if_ready!
      Result.new(status: :confirmed, profile:)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      return Result.new(status: :already_claimed, profile:) if error.message.include?("directory_profile_id")

      raise
    end

    def activate_if_ready!
      return Result.new(status: :pending, profile: @profile) unless @profile
      firm = @user.primary_firm
      return Result.new(status: :pending, profile: @profile) unless firm
      return Result.new(status: :protected, profile: @profile) if protected?(@profile) || protected?(firm)

      ApplicationRecord.transaction do
        @user.lock!
        @profile.lock!
        firm.lock!
        return Result.new(status: :protected, profile: @profile) if protected?(@profile) || protected?(firm)
        return Result.new(status: :pending, profile: @profile) unless identity_current?(@profile)
        if @user.email_verified? && !@profile.directory_email_verified? && same_email?(@user.email_address, @profile.directory_email)
          @profile.update!(directory_email_verified_at: Time.current)
        end
        return Result.new(status: :protected, profile: @profile) if protected?(@profile) || protected?(firm)
        return Result.new(status: :pending, profile: @profile) unless @profile.directory_matched? && @user.email_verified? && @profile.directory_email_verified?
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
      AuditEvent.create!(actor_user: @user, firm: @user.primary_firm, auditable: @profile, action:, metadata:)
    end
  end
end
