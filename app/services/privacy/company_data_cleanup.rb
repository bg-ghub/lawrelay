module Privacy
  # Retire member billing details while preserving workspaces and held evidence.
  class CompanyDataCleanup
    FIRM_FIELDS = %w[enterprise_number vat_number billing_email phone address_line_1 postal_code city].freeze
    ASSIGNMENT_FIELDS = %w[invoice_name invoice_enterprise_number invoice_email invoice_address_line_1 invoice_postal_code invoice_city].freeze
    BILLING_FIELDS = %w[billing_email peppol_id provider_customer_id].freeze
    Result = Data.define(:firms, :assignments, :billing_accounts, :protected_records)

    def initialize(dry_run: true, now: Time.current)
      @dry_run = dry_run
      @now = now
      @counts = Hash.new(0)
    end

    def call
      Firm.find_each do |firm|
        clear(firm, :firms, FIRM_FIELDS.index_with(nil).merge(
          "name" => Firm::INTERNAL_WORKSPACE_NAME, "kbo_details" => {}))
      end
      Assignment.find_each do |assignment|
        clear(assignment, :assignments, ASSIGNMENT_FIELDS.index_with(nil).merge("invoice_kbo_details" => {}))
      end
      BillingAccount.find_each do |account|
        clear(account, :billing_accounts, BILLING_FIELDS.index_with(nil))
      end
      RegistryStatus::Cleanup.new(now: @now).call unless @dry_run
      Result.new(**Result.members.index_with { |key| @counts[key] })
    end

    private

    def clear(record, counter, changes)
      record.with_lock do
        next unless changes.any? { |field, value| record.public_send(field) != value }

        if protected?(record)
          @counts[:protected_records] += 1
          next
        end
        @counts[counter] += 1
        record.update_columns(changes) unless @dry_run
      end
    end

    def protected?(record)
      firm = record.is_a?(Firm) ? record : record.firm
      account = record.is_a?(BillingAccount) ? record : firm&.billing_account
      return true if account && (account.invoices.exists? || account.billing_payments.exists? || account.subscriptions.exists?)

      protected_subject = record.is_a?(BillingAccount) ? firm : record
      Retention::Protection.held?(protected_subject, now: @now)
    end
  end
end
