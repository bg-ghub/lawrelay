require "digest"

module Accounts
  class Deletion
    class InvalidPassword < StandardError; end
    class InvalidSession < StandardError; end
    class Unavailable < StandardError; end

    GRACE_PERIOD = 30.days

    def self.schedule!(user:, current_session:, password:, now: Time.current)
      request = User.transaction do
        user.lock!
        authorize!(user, current_session:, password:)
        if user.deletion_pending?
          existing = user.deletion_request
          raise Unavailable unless existing&.current_cycle?(user)

          next existing
        end
        raise Unavailable if user.account_deletion_requests.pending.exists?
        Privacy::AccountErasure.check_protection!(user)
        record = user.account_deletion_requests.create!(requested_at: now, scheduled_at: now + GRACE_PERIOD,
          email_identity_digest: Digest::SHA256.hexdigest(user.email_address), requested_email_status: "pending")
        user.update!(deletion_request: record, deletion_requested_at: record.requested_at, deletion_scheduled_at: record.scheduled_at)
        user.sessions.destroy_all
        AuditEvent.create!(auditable: record, actor_user: user, firm: user.primary_firm,
          action: "account.deletion_requested", metadata: { scheduled_at: record.scheduled_at.utc.iso8601 })
        record
      end
      enqueue_notice(request, "requested")
      enqueue_finalization(request)
      request
    end

    def self.cancel!(user:, current_session:, password:, now: Time.current)
      request = User.transaction do
        user.lock!
        authorize!(user, current_session:, password:)
        record = user.deletion_request
        raise Unavailable unless record&.current_cycle?(user)

        record.lock!
        record.update!(cancelled_at: now, finalization_status: "cancelled", finalization_claimed_at: nil,
          finalization_enqueued_for: nil, finalization_retry_at: nil, finalization_reason: nil,
          cancelled_email_status: "pending", **stop_notice_attributes(record, "requested"))
        user.update!(deletion_request: nil, deletion_requested_at: nil, deletion_scheduled_at: nil)
        user.sessions.destroy_all
        AuditEvent.create!(auditable: record, actor_user: user, firm: user.primary_firm,
          action: "account.deletion_cancelled")
        record
      end
      close_cancelled_privacy_request(request)
      enqueue_notice(request, "cancelled")
      request
    end

    def self.finalize!(request:, ledger: Privacy::ErasureLedger.new, now: Time.current)
      raise Privacy::AccountErasure::ProtectedAccount, "Run scheduled erasure outside a database transaction" if User.connection.transaction_open?

      privacy_request = User.transaction do
        user = User.lock.find(request.user_id)
        request.reload
        next unless request.current_cycle?(user) && user.deletion_recoverable? &&
          request.finalization_status == "sending" && request.scheduled_at <= now

        existing = request.privacy_request
        if existing
          next unless existing.user_id == user.id && existing.kind == "deletion" &&
            existing.status == "pending" && existing.handled_by_user_id.nil?
        end
        Privacy::AccountErasure.check_protection!(user, ignored_privacy_request_id: existing&.id)
        existing ||= user.privacy_requests.create!(kind: "deletion", details: "Scheduled account deletion after the 30-day grace period.")
        request.update!(privacy_request: existing)
        existing
      end
      return false unless privacy_request

      user = privacy_request.user
      Privacy::AccountErasure.new(request: privacy_request, actor: user, ledger:, self_service: true,
        scheduled_deletion_request_id: request.id).call
    rescue Privacy::RequestContext::InvalidRequest
      close_cancelled_privacy_request(request.reload)
      false
    end

    # Run only during a controlled restore, before workers or traffic resume.
    # A database backup cannot prove whether a request was cancelled later.
    def self.pause_after_restore!(now: Time.current)
      count = 0
      AccountDeletionRequest.pending.find_each do |record|
        User.transaction do
          user = User.lock.find(record.user_id)
          record.reload
          next unless record.current_cycle?(user)

          record.update!(finalization_status: "paused", finalization_claimed_at: nil,
            finalization_enqueued_for: nil, finalization_retry_at: nil, finalization_reason: nil,
            **stop_notice_attributes(record, "requested"), **stop_notice_attributes(record, "cancelled"))
          user.sessions.destroy_all
          AuditEvent.create!(auditable: record, action: "account.deletion_paused_after_restore", created_at: now)
          count += 1
        end
      end
      count
    end

    def self.enqueue_notice(request, kind)
      return unless request.reserve_notice_enqueue!(kind)

      result = AccountDeletionNoticeJob.perform_later(request.id, kind)
      raise ActiveJob::EnqueueError, "Deletion notice enqueue rejected" unless result
    rescue StandardError => error
      request.release_notice_enqueue!(kind)
      Rails.logger.error("Account deletion notice enqueue failed: #{error.class} (request #{request.id})")
      false
    end

    def self.reconcile_cancelled_privacy_requests
      AccountDeletionRequest.joins(:privacy_request).where.not(cancelled_at: nil)
        .where(privacy_requests: { status: %w[pending in_review] }).find_each do |record|
        close_cancelled_privacy_request(record)
      end
    end

    def self.enqueue_finalization(request)
      target = request.reserve_finalization_enqueue!
      return unless target

      result = FinalizeAccountDeletionJob.set(wait_until: target).perform_later(request.id)
      raise ActiveJob::EnqueueError, "Deletion finalization enqueue rejected" unless result
    rescue StandardError => error
      request.release_finalization_enqueue!
      Rails.logger.error("Account deletion finalization enqueue failed: #{error.class} (request #{request.id})")
      false
    end

    def self.authorize!(user, current_session:, password:)
      raise Unavailable if user.system_admin? || user.erased_at || user.suspended?
      active_session = user.sessions.lock.find_by(id: current_session&.id)
      raise InvalidSession unless active_session && !active_session.expired?
      active_session.user = user
      raise InvalidSession if user.two_factor_enabled? && !active_session.two_factor_verified?
      raise InvalidPassword unless user.authenticate(password.to_s)
    end

    def self.stop_notice_attributes(record, kind)
      return {} if record.public_send("#{kind}_email_status").in?([ nil, "sent", "skipped" ])

      { "#{kind}_email_status" => "skipped", "#{kind}_email_claimed_at" => nil,
        "#{kind}_email_enqueued_at" => nil, "#{kind}_email_retry_at" => nil, "#{kind}_email_reason" => "superseded" }
    end

    def self.close_cancelled_privacy_request(record)
      return unless record.cancelled_at && record.privacy_request_id

      request = PrivacyRequest.find_by(id: record.privacy_request_id, user_id: record.user_id, kind: "deletion")
      request&.with_lock do
        if request.status.in?(%w[pending in_review])
          request.update!(status: "rejected", resolved_at: record.cancelled_at,
            resolution_note: request.resolution_note.presence || "Cancelled by the account owner.")
          request.audit_events.create!(actor_user: record.user, action: "privacy_request.withdrawn",
            metadata: { account_deletion_request_id: record.id })
        end
      end
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("Cancelled deletion request cleanup failed: #{error.class} (request #{record.id})")
    end

    private_class_method :authorize!, :stop_notice_attributes, :close_cancelled_privacy_request
  end
end
