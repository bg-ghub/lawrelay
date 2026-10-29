namespace :retention do
  desc "Preview retention cleanup; use APPLY=true to execute the same reviewed policy"
  task cleanup: :environment do
    result = Retention::Cleanup.new(dry_run: ENV["APPLY"] != "true").call
    puts JSON.generate(dry_run: ENV["APPLY"] != "true", counts: result.to_h)
  end

  desc "Place a 90-day retention hold (TYPE, ID, ACTOR_ID, REASON required)"
  task hold: :environment do
    type = ENV.fetch("TYPE")
    abort "Unsupported hold subject." unless RetentionHold::SUBJECT_TYPES.include?(type)
    actor = User.find(ENV.fetch("ACTOR_ID"))
    subject = type.constantize.find(ENV.fetch("ID"))
    hold = RetentionHold.create!(subject:, actor:, reason: ENV.fetch("REASON"), expires_at: 90.days.from_now)
    AuditEvent.create!(auditable: subject, actor_user: actor, action: "retention.hold_placed", metadata: { hold_id: hold.id })
    puts "Retention hold #{hold.id} expires #{hold.expires_at.utc.iso8601}; review before renewal."
  end
end

namespace :privacy do
  desc "Erase a reviewed member account (request_id, actor_id; CONFIRM=ERASE required)"
  task :erase, [ :request_id, :actor_id ] => :environment do |_task, arguments|
    abort "Set CONFIRM=ERASE after reviewing identity, shared records, holds and the response." unless ENV["CONFIRM"] == "ERASE"
    request = PrivacyRequest.find(arguments[:request_id])
    actor = User.find(arguments[:actor_id])
    Privacy::AccountErasure.new(request:, actor:).call
    puts "Account profile and access erased; minimal shared records follow the retention policy. Review external mail separately."
  end

  desc "Replay the protected erasure ledger before restored traffic or workers resume"
  task reapply_erasures: :environment do
    count = Privacy::AccountErasure.reapply!
    puts "Reapplied #{count} reviewed account erasures."
  end
end
