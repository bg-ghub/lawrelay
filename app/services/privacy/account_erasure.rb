require "bcrypt"

module Privacy
  class AccountErasure
    class ProtectedAccount < StandardError; end

    def initialize(request:, actor:, ledger: ErasureLedger.new)
      @request = request
      @actor = actor
      @ledger = ledger
      @context = RequestContext.new(request:, actor:, kind: "deletion")
    end

    def call
      raise ProtectedAccount, "Run reviewed erasure outside an existing database transaction" if User.connection.transaction_open?

      operation = nil
      User.transaction do
        @request.lock!
        @context.validate!
        user = @context.user
        user.lock!
        raise ProtectedAccount, "This member account has already been erased" if user.erased_at
        self.class.check_protection!(user, ignored_privacy_request_id: @request.id)
        erased_at = Time.current
        operation = @ledger.stage!(user, erased_at:)
        self.class.scrub!(user, erased_at:)
        @request.reload.update!(status: "completed", resolved_at: erased_at, handled_by_user: @actor)
        AuditEvent.create!(auditable: user, actor_user: @actor, action: "privacy.account_erased", metadata: {})
      end
      @ledger.commit!(operation)
      true
    rescue StandardError
      # If SQL committed, a pending ledger entry can be reconciled from the
      # exact erased_at timestamp. Never mark that committed action aborted.
      @ledger.abort!(operation) if operation && @context.user.reload.erased_at.nil?
      raise
    end

    def self.reapply!(ledger: ErasureLedger.new)
      ledger.reconcile!
      count = 0
      ledger.entries.each do |entry|
        User.transaction do
          user = User.lock.find_by(id: entry.fetch("user_id"))
          next unless user
          raise ProtectedAccount, "Erasure ledger account identity does not match restored data" unless user.created_at.utc.iso8601(6) == entry.fetch("user_created_at")
          raise ProtectedAccount, "The erasure ledger cannot apply to administrators" if user.system_admin?
          next if user.erased_at

          # This is replay of a previously reviewed action, before traffic and
          # workers resume. Restored open states must not revive erased data.
          scrub!(user, erased_at: Time.iso8601(entry.fetch("erased_at")))
          count += 1
        end
      end
      count
    end

    def self.check_protection!(user, ignored_privacy_request_id: nil)
      raise ProtectedAccount, "Administrator accounts are excluded" if user.system_admin?
      raise ProtectedAccount, "Resolve the recorded hold or open request first" if Retention::Protection.held?(user, ignored_privacy_request_id:)
      related_work = Assignment.where(creator_user_id: user.id).or(Assignment.where(id: user.proposals.select(:assignment_id)))
      if related_work.any? { |assignment| Retention::Protection.held?(assignment, ignored_privacy_request_id:) }
        raise ProtectedAccount, "Resolve the related assignment, report or participant hold first"
      end
      ongoing = user.created_assignments.where(status: %w[draft open matched]).exists? ||
        user.proposals.joins(:assignment).where(assignments: { status: %w[draft open matched] }).exists?
      raise ProtectedAccount, "Resolve ongoing assignments and proposals before account erasure" if ongoing
      raise ProtectedAccount, "Review billing evidence before account erasure" if user.firms.joins(billing_account: :invoices).exists? ||
        user.firms.joins(billing_account: :billing_payments).exists? || user.firms.joins(billing_account: :subscriptions).exists?
    end

    def self.scrub!(user, erased_at:)
      raise ProtectedAccount, "Administrator accounts are excluded" if user.system_admin?
      locale = user.locale
      removed = I18n.t("retention.removed_content", locale:)
      firm_ids = user.firm_ids
      sole_firm_ids = firm_ids.reject { |id| Membership.where(firm_id: id).where.not(user_id: user.id).exists? }
      profile_id = user.lawyer_profile&.id
      subjects = { "User" => [ user.id ], "LawyerProfile" => [ profile_id ].compact,
        "Assignment" => user.created_assignments.pluck(:id), "Proposal" => user.proposals.pluck(:id),
        "PrivacyRequest" => user.privacy_requests.pluck(:id), "Report" => user.submitted_reports.pluck(:id), "Firm" => sole_firm_ids }
      subjects.each { |type, ids| AuditEvent.where(auditable_type: type, auditable_id: ids).update_all(metadata: {}) }
      AuditEvent.where(actor_user_id: user.id).update_all(metadata: {})

      user.sessions.destroy_all
      user.notifications.destroy_all
      user.lawyer_profile&.destroy!
      user.proposals.update_all(name: nil, email: nil, message: removed)
      user.created_assignments.update_all(title: removed, description: removed, scope_indication: nil)
      user.created_assignments.where(status: %w[draft open matched]).update_all(status: "cancelled", closed_at: erased_at)
      user.proposals.joins(:assignment).where(assignments: { status: %w[draft open matched] })
        .update_all(status: "withdrawn", withdrawn_at: erased_at)
      user.privacy_requests.update_all(details: removed, resolution_note: nil)
      user.privacy_requests.where(kind: "deletion").update_all(status: "completed", resolved_at: erased_at)
      user.submitted_reports.update_all(details: removed, resolution_note: nil)
      Firm.where(id: sole_firm_ids).update_all(name: I18n.t("retention.deleted_account", locale:), enterprise_number: nil,
        vat_number: nil, billing_email: nil, phone: nil, address_line_1: nil, postal_code: nil, city: nil,
        verification_status: "pending", verified_at: nil)
      BillingAccount.where(firm_id: sole_firm_ids).update_all(billing_email: nil, peppol_id: nil, provider_customer_id: nil)
      user.memberships.destroy_all
      user.update_columns(first_name: "", last_name: "", email_address: "erased-#{SecureRandom.uuid}@lawrelay.invalid",
        password_digest: BCrypt::Password.create(SecureRandom.hex(40)), email_verified_at: nil,
        suspended_at: erased_at, suspension_reason: nil, erased_at:, updated_at: erased_at,
        admin_mfa_secret_ciphertext: nil, admin_mfa_pending_secret_ciphertext: nil, admin_mfa_enabled_at: nil, admin_mfa_last_verified_at: nil,
        two_factor_secret_ciphertext: nil, two_factor_pending_secret_ciphertext: nil, two_factor_enabled_at: nil,
        two_factor_last_verified_at: nil, two_factor_recovery_code_digests: [],
        accepted_terms_at: nil, accepted_terms_version: nil, accepted_privacy_version: nil)
    end
  end
end
