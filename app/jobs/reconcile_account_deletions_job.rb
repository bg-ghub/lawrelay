class ReconcileAccountDeletionsJob < ApplicationJob
  queue_as :default

  def perform
    Accounts::Deletion.reconcile_cancelled_privacy_requests
    AccountDeletionRequest.pending.where(finalization_status: %w[pending sending]).find_each do |request|
      Accounts::Deletion.enqueue_finalization(request)
    end
    AccountDeletionRequest::NOTICE_KINDS.each do |kind|
      AccountDeletionRequest.deliverable_notices(kind).find_each do |request|
        Accounts::Deletion.enqueue_notice(request, kind)
      end
    end
  end
end
