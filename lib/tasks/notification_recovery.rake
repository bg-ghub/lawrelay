namespace :lawrelay do
  desc "Review recent notification emails skipped before approval; APPLY=true restores eligible events to the outbox"
  task recover_skipped_notification_emails: :environment do
    result = Notifications::RecoverSkippedEmails.new(dry_run: ENV["APPLY"] != "true").call
    puts JSON.generate(dry_run: result.dry_run, eligible_count: result.notification_ids.length, notification_ids: result.notification_ids)
  end
end
