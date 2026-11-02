namespace :privacy do
  desc "Pause restored account deletion requests before workers or traffic resume"
  task pause_account_deletions: :environment do
    count = Accounts::Deletion.pause_after_restore!
    puts "Restored account deletion requests paused: #{count}"
  end
end
