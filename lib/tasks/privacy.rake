namespace :privacy do
  desc "Prepare a private member access-review package (OUTPUT=/protected/new.json)"
  task :export, [ :request_id, :actor_id ] => :environment do |_task, arguments|
    PrivacyTasks.prepare(Privacy::AccountExport, arguments)
  end

  desc "Prepare a non-mutating member erasure inventory (OUTPUT=/protected/new.json)"
  task :erasure_inventory, [ :request_id, :actor_id ] => :environment do |_task, arguments|
    PrivacyTasks.prepare(Privacy::ErasureInventory, arguments)
  end
end

module PrivacyTasks
  def self.prepare(service, arguments)
    request_id = arguments[:request_id].to_s
    actor_id = arguments[:actor_id].to_s
    abort "Provide a privacy request ID and administrator ID." unless [ request_id, actor_id ].all? { |id| id.match?(/\A[1-9]\d*\z/) }
    abort "Provide OUTPUT as a new absolute file path in a protected directory." if ENV["OUTPUT"].blank?

    request = PrivacyRequest.find(request_id)
    actor = User.find(actor_id)
    service.new(request:, actor:).call(output_path: ENV.fetch("OUTPUT"))
    puts "Private review package saved. Review it before any release or erasure decision; the request remains open."
  rescue ActiveRecord::RecordNotFound, Privacy::RequestContext::InvalidRequest, Privacy::PrivateJsonFile::UnsafePath => error
    abort(error.is_a?(ActiveRecord::RecordNotFound) ? "Request or administrator not found." : error.message)
  end
end
