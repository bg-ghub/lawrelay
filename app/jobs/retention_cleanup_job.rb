class RetentionCleanupJob < ApplicationJob
  queue_as :default

  def perform
    ledger = Privacy::ErasureLedger.new if ENV["LAWRELAY_ERASURE_LEDGER"].present?
    ledger&.reconcile!
    Retention::Cleanup.new(dry_run: false).call
    Privacy::CompanyDataCleanup.new(dry_run: false).call
    ledger&.prune!
  end
end
