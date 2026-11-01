module Directory
  class ProfileSync
    Result = Data.define(:status, :changed_fields) do
      def success? = status.in?(%i[updated unchanged])
    end

    IMPORTED_FIELDS = %w[spoken_languages practice_areas].freeze
    USER_IDENTITY_FIELDS = %w[id first_name last_name email_address system_role suspended_at erased_at].freeze
    PROFILE_IDENTITY_FIELDS = %w[id user_id directory_profile_url directory_profile_id directory_name
      directory_email directory_checked_at verification_status].freeze

    def self.call(user:, import: ProfileImport, actor: nil)
      new(user:, import:, actor:).call
    end

    def initialize(user:, import: ProfileImport, actor: nil)
      @user_id = user.id
      @import = import
      @actor = actor
    end

    def call
      user = User.find_by(id: @user_id)
      profile = LawyerProfile.find_by(user_id: @user_id)
      return result(:ineligible) unless eligible?(user, profile)

      identity = identity_for(user, profile)
      imported = @import.call(profile_url: profile.directory_profile_url, full_name: user.full_name)
      return result(imported.status) unless imported.success?

      attributes = imported.profile_attributes.to_h.stringify_keys.slice(*IMPORTED_FIELDS)
      return result(:empty) if attributes.empty?

      ApplicationRecord.transaction do
        current_user = User.lock.find_by(id: @user_id)
        current_profile = LawyerProfile.lock.find_by(user_id: @user_id)
        next result(:stale) unless eligible?(current_user, current_profile) && identity_for(current_user, current_profile) == identity

        current_profile.assign_attributes(attributes)
        changed_fields = IMPORTED_FIELDS.select { |field| current_profile.will_save_change_to_attribute?(field) }
        next result(:unchanged) if changed_fields.empty?

        current_profile.save!
        AuditEvent.create!(auditable: current_profile, actor_user: @actor, firm: current_user.primary_firm,
          action: "profile.directory_synced", metadata: { changed_fields:, source: "advocaat.be" })
        result(:updated, changed_fields:)
      end
    rescue ActiveRecord::RecordInvalid
      result(:invalid_data)
    end

    private

    def eligible?(user, profile)
      user&.active? && !user.system_admin? && profile&.directory_matched? &&
        !profile.verification_status.in?(%w[rejected suspended]) &&
        AdvocaatBeProfileLookup.valid_profile_url?(profile.directory_profile_url) &&
        AdvocaatBeProfileLookup.names_match?(profile.directory_name, user.full_name)
    end

    def identity_for(user, profile)
      [ user.attributes.slice(*USER_IDENTITY_FIELDS), profile.attributes.slice(*PROFILE_IDENTITY_FIELDS, *IMPORTED_FIELDS) ]
    end

    def result(status, changed_fields: [])
      Result.new(status:, changed_fields:)
    end
  end
end
