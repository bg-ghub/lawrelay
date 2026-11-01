module Accounts
  class RequestEmailAccess
    Result = Data.define(:success?, :user, :profile, :errors, :request_created)

    def self.call(user:, current_session:, password:, email_address:, reason: nil)
      new(user:, current_session:, password:, email_address:, reason:).call
    end

    def initialize(user:, current_session:, password:, email_address:, reason: nil)
      @user, @current_session, @password = user, current_session, password
      @email_address = email_address.to_s.strip.downcase
      @reason = reason.is_a?(String) ? reason.strip : nil
    end

    def call
      user = profile = nil
      ApplicationRecord.transaction do
        user = User.lock.find(@user.id)
        return failure(user, nil, :unavailable) unless user.active? && !user.system_admin?
        session = user.sessions.lock.find_by(id: @current_session&.id)
        return failure(user, nil, :unavailable) unless session && !session.expired?
        return failure(user, nil, :password) unless user.authenticate(@password.to_s)

        profile = LawyerProfile.lock.find_by(user_id: user.id)
        firm = user.primary_firm
        return failure(user, profile, :incomplete) unless profile && firm
        return failure(user, profile, :protected) if [ profile, firm ].any? { |record| record.verification_status.in?(%w[rejected suspended]) }
        return failure(user, profile, :directory_required) unless Directory::AdvocaatBeProfileLookup.valid_profile_url?(profile.directory_profile_url)
        if profile.email_review_pending? && profile.email_review_email_address == @email_address && user.email_address == @email_address
          unless profile.email_review_request_reason.present?
            reason_error = reason_failure_key
            return failure(user, profile, reason_error) if reason_error

            profile.update!(email_review_request_reason: @reason)
            AuditEvent.create!(auditable: profile, actor_user: user, firm: firm,
              action: "account.updated", metadata: { changed_fields: [ "email_review_request_reason" ] })
          end
          return Result.new(true, user, profile, [], false)
        end
        return failure(user, profile, :already_reviewed) if profile.email_review_approved? && user.email_address == @email_address
        if user.email_address == @email_address && (!profile.directory_matched? || profile.directory_email.to_s.casecmp?(@email_address))
          return failure(user, profile, :unchanged)
        end
        reason_error = reason_failure_key
        return failure(user, profile, reason_error) if reason_error

        user.update!(email_address: @email_address)
        profile.clear_email_review
        profile.assign_attributes(professional_email: user.email_address, verification_status: "pending", verified_at: nil,
          verification_note: nil, directory_email_verified_at: nil, directory_confirmation_requested_at: nil,
          email_review_status: "pending", email_review_email_address: user.email_address, email_review_requested_at: Time.current,
          email_review_request_reason: @reason)
        profile.save!
        user.sessions.where.not(id: session.id).destroy_all
        AuditEvent.create!(auditable: profile, actor_user: user, firm: firm,
          action: "email_access.requested", metadata: {})
      end
      Result.new(true, user, profile, [], true)
    rescue ActiveRecord::RecordInvalid => error
      Result.new(false, user || @user, profile, error.record.errors.full_messages, false)
    rescue ActiveRecord::RecordNotUnique
      failure(user || @user, profile, :claimed)
    rescue ActiveRecord::RecordNotFound
      failure(@user, nil, :unavailable)
    end

    private

    def reason_failure_key
      return :reason_required if @reason.blank?
      :reason_too_long if @reason.length > 1_000
    end

    def failure(user, profile, key)
      Result.new(false, user, profile, [ I18n.t("email_access.errors.#{key}") ], false)
    end
  end
end
