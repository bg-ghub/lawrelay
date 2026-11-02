class FinalizeAccountDeletionJob < ApplicationJob
  queue_as :default

  def perform(request_id)
    request = AccountDeletionRequest.find_by(id: request_id)
    return unless request&.claim_finalization!

    completed = Accounts::Deletion.finalize!(request:)
    request.reload
    if !completed && request.finalization_status == "sending"
      request.update!(finalization_status: "paused", finalization_claimed_at: nil,
        finalization_enqueued_for: nil, finalization_reason: "review_required")
    end
  rescue Privacy::ErasureLedger::UnsafeLedger => error
    if request && request.reload.completed_at.nil?
      request.update!(finalization_status: "failed", finalization_claimed_at: nil,
        finalization_enqueued_for: nil, finalization_reason: error.class.name)
    end
    raise
  rescue StandardError => error
    request&.fail_finalization!(error:)
    Rails.logger.error("Account deletion finalization failed: #{error.class} (request #{request_id})")
  end
end
