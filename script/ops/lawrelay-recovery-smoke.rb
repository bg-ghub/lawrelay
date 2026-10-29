# Only for the network-isolated temporary restore container. Never run on live data.
abort "Recovery smoke requires the isolated drill hostname." unless ENV["APP_HOST"] == "drill.lawrelay.invalid"
abort "Recovery smoke must not have SMTP configuration." if ENV["SMTP_ADDRESS"].present? || ENV["SMTP_PASSWORD"].present?
abort "Recovery smoke must not run queue workers." unless ENV["SOLID_QUEUE_IN_PUMA"] == "false"
abort "Recovery smoke is for production-schema copies." unless Rails.env.production?

Rails.logger.level = Logger::WARN
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = false

def check(condition, description)
  abort "Recovery check failed: #{description}" unless condition
  puts "Recovery check passed: #{description}"
end

def visit(session, path)
  session.get(path)
  session.response
end

restored_users = User.count
restored_assignments = Assignment.count
puts "Restored records readable: users=#{restored_users}, assignments=#{restored_assignments}"
check(ActiveRecord::Base.connection_pool.migration_context.needs_migration? == false, "current schema is prepared")
ReadinessController.database_ready?
ReadinessController.storage_ready?
check(true, "all databases and storage are readable/writable")

anonymous = ActionDispatch::Integration::Session.new(Rails.application)
anonymous.host! "drill.lawrelay.invalid"
anonymous.https!
%w[nl fr de en].each do |locale|
  check(visit(anonymous, "/#{locale}").status == 200, "#{locale} homepage renders")
end
check(visit(anonymous, "/ready").status == 200, "readiness route")
check(visit(anonymous, "/nl/assignments").redirect?, "anonymous marketplace access is denied")

# Older released images do not expose operational queue health. New images
# exercise the degraded/recovered response using only this disposable queue.
operations_route = begin
  Rails.application.routes.recognize_path("/health/operations", method: :get)
rescue ActionController::RoutingError
  nil
end
if operations_route
  check(visit(anonymous, "/health/operations").status == 200, "operations route is healthy")
  failed_job = SolidQueue::Job.create!(queue_name: "recovery_drill", class_name: "RecoverySyntheticJob", arguments: {}, active_job_id: SecureRandom.uuid)
  begin
    SolidQueue::FailedExecution.create!(job: failed_job, error: { "exception_class" => "RecoverySyntheticFailure", "message" => "Synthetic isolated failure", "backtrace" => [] })
    response = visit(anonymous, "/health/operations")
    body = JSON.parse(response.body)
    check(response.status == 503 && body.keys == [ "status" ] && body["status"] != "ok", "queue failure produces a minimal unhealthy operations response")
  ensure
    failed_job.destroy!
  end
  check(visit(anonymous, "/health/operations").status == 200, "operations route recovers after synthetic cleanup")
end

nonce = SecureRandom.hex(6)
password = SecureRandom.base64(32)
user = User.create!(first_name: "Recovery", last_name: "Drill", email_address: "recovery-#{nonce}@example.invalid", password:, email_verified_at: Time.current, locale: "nl")
firm = Firm.create!(name: "Recovery drill #{nonce}", verification_status: "verified", verified_at: Time.current)
Membership.create!(user:, firm:, role: "owner")
LawyerProfile.create!(user:, bar_association: "Recovery drill", bar_number: "DRILL-#{nonce}", verification_status: "verified", verified_at: Time.current)
other_firm = Firm.create!(name: "Unrelated recovery drill #{nonce}", verification_status: "verified", verified_at: Time.current)
attributes = { kind: "court_replacement", assignment_subtype: "hearing", title: "Recovery drill", description: "Synthetic recovery exercise without client information.", practice_area: "Civil", starts_at: 2.days.from_now, city: "Gent", court: "Recovery drill", duration_minutes: 30, status: "draft", content_rules_accepted_at: Time.current }
own_assignment = Assignment.create!(**attributes, firm:, creator_user: user)
private_assignment = Assignment.create!(**attributes, firm: other_firm)

member = ActionDispatch::Integration::Session.new(Rails.application)
member.host! "drill.lawrelay.invalid"
member.https!
visit(member, "/nl/session/new")
csrf = Nokogiri::HTML(member.response.body).at_css('input[name="authenticity_token"]')&.[]("value")
check(csrf.present?, "login CSRF token is present")
member.post("/nl/session", params: { email_address: user.email_address, password:, authenticity_token: csrf })
check(member.response.redirect? && member.cookies["session_id"].present?, "synthetic user can authenticate")
check(visit(member, "/nl/dashboard").status == 200, "authenticated dashboard renders")
check(visit(member, "/nl/assignments").status == 200, "verified marketplace access succeeds")
check(visit(member, "/nl/assignments/#{own_assignment.id}").status == 200, "own private assignment remains readable")
check(visit(member, "/nl/assignments/#{private_assignment.id}").redirect?, "unrelated private assignment is denied")
check(visit(member, "/nl/admin/verifications").status.in?([ 302, 303, 403 ]), "member cannot use administration")
check(ActionMailer::Base.deliveries.empty?, "no email was delivered")

# Execute only newly-created synthetic jobs from this disposable queue. Never
# drain the restored queue: it may contain real recipients from the snapshot.
if defined?(NotificationEmailDeliveryJob)
  candidates = %w[selected declined].map.with_index do |label, index|
    candidate = User.create!(first_name: "Recovery", last_name: label.capitalize,
      email_address: "recovery-#{label}-#{nonce}@example.invalid", password:,
      email_verified_at: Time.current, locale: %w[fr de][index])
    candidate_firm = Firm.create!(name: "Recovery #{label} #{nonce}", verification_status: "verified", verified_at: Time.current)
    Membership.create!(user: candidate, firm: candidate_firm, role: "owner")
    LawyerProfile.create!(user: candidate, bar_association: "Recovery drill", bar_number: "DRILL-#{label}-#{nonce}",
      verification_status: "verified", verified_at: Time.current)
    candidate
  end
  own_assignment.update!(status: "open")
  proposals = candidates.map do |candidate|
    own_assignment.proposals.create!(user: candidate, firm: candidate.primary_firm, message: "Synthetic recovery response.", rate_cents: 0, rate_kind: "fixed")
  end
  pending = Notification.where(subject: proposals, kind: "new_proposal").to_a
  check(pending.size == 2 && pending.all? { |notice| notice.user_id == user.id }, "synthetic response notifications persisted")

  deliver_synthetic = lambda do |notice|
    job = SolidQueue::Job.where(class_name: "NotificationEmailDeliveryJob").order(id: :desc).find do |entry|
      entry.arguments.fetch("arguments", []) == [ notice.id ]
    end
    check(job.present?, "synthetic notification has a serialized queue job")
    prior_count = ActionMailer::Base.deliveries.size
    ActionMailer::Base.perform_deliveries = true
    ActiveJob::Base.execute(job.arguments)
    message = ActionMailer::Base.deliveries.last
    check(notice.reload.email_status == "sent" && ActionMailer::Base.deliveries.size == prior_count + 1,
      "serialized notification job completes through the test mail adapter")
    check(message.to == [ notice.user.email_address ] && message.bcc.blank?, "notification has one intended synthetic recipient")
    job.destroy!
  end
  pending.each(&deliver_synthetic)
  own_assignment.with_lock do
    proposals.first.accept!(actor: user)
    proposals.last.decline!(actor: user)
    own_assignment.update!(status: "matched")
  end
  decisions = Notification.where(subject: proposals, kind: %w[proposal_accepted proposal_declined]).to_a
  check(decisions.size == 2, "selection and non-selection notifications persisted")
  decisions.each(&deliver_synthetic)
  ActionMailer::Base.deliveries.clear
  ActionMailer::Base.perform_deliveries = false
  check(ActionMailer::Base.delivery_method == :test && ActionMailer::Base.deliveries.empty?, "mail stayed local and the capture was cleared")
end

if defined?(Privacy::AccountExport)
  require "tmpdir"
  operator = User.create!(first_name: "Recovery", last_name: "Operator", system_role: "admin",
    email_address: "recovery-operator-#{nonce}@example.invalid", password:, email_verified_at: Time.current)
  setup_secret = operator.begin_admin_mfa_setup!
  operator.enable_admin_mfa!(ROTP::TOTP.new(setup_secret, issuer: "LawRelay").now)
  access_request = user.privacy_requests.create!(kind: "access_export", status: "in_review", handled_by_user: operator,
    details: "Synthetic recovery access request.")
  deletion_request = user.privacy_requests.create!(kind: "deletion", status: "in_review", handled_by_user: operator,
    details: "Synthetic recovery deletion inventory.")
  Dir.mktmpdir("lawrelay-private-recovery-") do |directory|
    access_path = File.join(directory, "access.json")
    inventory_path = File.join(directory, "inventory.json")
    Privacy::AccountExport.new(request: access_request, actor: operator).call(output_path: access_path)
    package = JSON.parse(File.read(access_path))
    check(package.dig("account", "id") == user.id && package.fetch("authored_proposals").empty?, "privacy export stays scoped to its synthetic account")
    check(!package.fetch("account").key?("password_digest") && (File.stat(access_path).mode & 0o777) == 0o600,
      "privacy export excludes password material and uses private permissions")
    before_inventory = [ User.count, Session.count, Assignment.count, Proposal.count ]
    Privacy::ErasureInventory.new(request: deletion_request, actor: operator).call(output_path: inventory_path)
    inventory = JSON.parse(File.read(inventory_path))
    check(inventory["deletion_performed"] == false && inventory["hold_decision"] == "not_assessed" &&
      before_inventory == [ User.count, Session.count, Assignment.count, Proposal.count ], "erasure inventory neither deletes records nor decides a hold")
    check(access_request.reload.status == "in_review" && deletion_request.reload.status == "in_review", "privacy preparation leaves requests open for review")
  end
end
puts "Isolated synthetic records stay in the disposable restore copy."
