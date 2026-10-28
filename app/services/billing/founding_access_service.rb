module Billing
  class FoundingAccessService
    class InvalidExpiry < StandardError; end
    class IneligibleFirm < StandardError; end
    class PaidAccount < StandardError; end

    MAXIMUM_DURATION = 1.year

    def grant!(firm:, expires_on:, actor:)
      validate_expiry!(expires_on)

      ApplicationRecord.transaction do
        firm.lock!
        raise IneligibleFirm unless firm.verified?

        account = billing_account_for!(firm)
        raise PaidAccount unless account.plan_key == "founding_beta"

        account.update!(status: "active", complimentary_access_until: expires_on.end_of_day)
        record_audit_event!(firm:, account:, actor:, action: "billing.founding_access_granted", expires_on:)
        account
      end
    end

    def revoke!(firm:, actor:)
      ApplicationRecord.transaction do
        firm.lock!
        account = firm.billing_account
        return unless account&.plan_key == "founding_beta" && account.complimentary_access_until.present?

        account.update!(status: "pending", complimentary_access_until: nil)
        record_audit_event!(firm:, account:, actor:, action: "billing.founding_access_revoked")
        account
      end
    end

    private

    def validate_expiry!(expires_on)
      raise InvalidExpiry unless expires_on.is_a?(Date)
      raise InvalidExpiry if expires_on < Date.current || expires_on > Date.current + MAXIMUM_DURATION
    end

    def billing_account_for!(firm)
      BillingAccount.find_or_create_by!(firm:) do |account|
        account.billing_email = firm.billing_email || firm.users.order(:id).pick(:email_address)
        account.plan_key = "founding_beta"
        account.status = "pending"
      end.lock!
    end

    def record_audit_event!(firm:, account:, actor:, action:, expires_on: nil)
      AuditEvent.create!(
        auditable: account,
        actor_user: actor,
        firm:,
        action:,
        metadata: { expires_on: expires_on&.iso8601 }.compact
      )
    end
  end
end
