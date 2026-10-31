namespace :privacy do
  desc "Remove retired member company details; preserve protected financial evidence"
  task remove_member_company_data: :environment do
    dry_run = ENV["DRY_RUN"] == "true"
    result = Privacy::CompanyDataCleanup.new(dry_run:).call
    puts "Member company data cleanup#{' (dry run)' if dry_run}: #{result.to_h.to_json}"
  end
end
