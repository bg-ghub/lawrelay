module Accounts
  class ChangeEmail
    Result = Data.define(:success?, :user, :profile, :errors)

    def self.call(user:, current_session:, password:, email_address:)
      new(user:, current_session:, password:, email_address:).call
    end

    def initialize(user:, current_session:, password:, email_address:)
      @user = user
      @current_session = current_session
      @password = password
      @email_address = email_address
    end

    def call
      changed_user = nil
      changed_profile = nil

      ApplicationRecord.transaction do
        changed_user = User.lock.find(@user.id)
        return failure(changed_user, nil, :unavailable) unless changed_user.active? && !changed_user.system_admin?
        current_session = changed_user.sessions.lock.find_by(id: @current_session&.id)
        return failure(changed_user, nil, :unavailable) unless current_session && !current_session.expired?
        return failure(changed_user, nil, :password) unless changed_user.authenticate(@password.to_s)
        return failure(changed_user, nil, :unchanged) if normalized_email == changed_user.email_address

        changed_profile = LawyerProfile.lock.find_by(user_id: changed_user.id)
        changed_user.update!(email_address: @email_address)
        clear_directory_evidence!(changed_profile) if changed_profile
        reset_profile_verification!(changed_profile) if changed_profile
        changed_profile&.save!
        AuditEvent.create!(
          auditable: changed_user, actor_user: changed_user, firm: changed_user.primary_firm,
          action: "account.email_changed", metadata: { profile_id: changed_profile&.id }
        )

        # Leave the browser completing this request signed in so its owner can
        # follow the verification link, while invalidating every other device.
        changed_user.sessions.where.not(id: current_session.id).destroy_all
      end

      Result.new(true, changed_user, changed_profile, [])
    rescue ActiveRecord::RecordInvalid => error
      Result.new(false, changed_user || @user, changed_profile, error.record.errors.full_messages)
    rescue ActiveRecord::RecordNotFound
      Result.new(false, @user, nil, [ I18n.t("email_change.errors.unavailable") ])
    end

    private

    def failure(user, profile, type)
      key = { password: :password, unchanged: :unchanged, unavailable: :unavailable }.fetch(type)
      message = I18n.t("email_change.errors.#{key}")
      Result.new(false, user, profile, [ message ])
    end

    def normalized_email
      @email_address.to_s.strip.downcase
    end

    def clear_directory_evidence!(profile)
      profile.assign_attributes(
        directory_profile_id: nil, directory_name: nil, directory_email: nil,
        directory_checked_at: nil, directory_email_verified_at: nil,
        directory_confirmation_requested_at: nil, directory_identity_digest: nil
      )
    end

    def reset_profile_verification!(profile)
      return if profile.verification_status.in?(%w[rejected suspended])

      profile.assign_attributes(verification_status: "pending", verified_at: nil, verification_note: nil)
    end
  end
end
