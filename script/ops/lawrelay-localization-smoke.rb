# Frozen production-only localization rendering drill. It is intentionally run
# only in a newly-created, network-isolated container with disposable storage.
abort "Localization smoke requires the isolated hostname." unless ENV["APP_HOST"] == "i18n.lawrelay.invalid"
abort "Localization smoke must run in production." unless Rails.env.production?
abort "Localization smoke must not have SMTP credentials." if ENV.keys.grep(/\ASMTP_(ADDRESS|USERNAME|PASSWORD)\z/).any? { |key| ENV[key].present? }
abort "Localization smoke must not run queue workers." unless ENV["SOLID_QUEUE_IN_PUMA"] == "false"
abort "Localization smoke requires an empty disposable database." unless User.none? && Firm.none? && Assignment.none?

require "cgi"

Rails.logger.level = Logger::WARN
Rails.application.config.i18n.raise_on_missing_translations = true
ActionView::Helpers::TranslationHelper.raise_on_missing_translations = true
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = false
ActionMailer::Base.deliveries.clear
I18n.fallbacks = I18n::Locale::Fallbacks.new
I18n.exception_handler = ->(exception, *) { raise(exception.respond_to?(:to_exception) ? exception.to_exception : exception) }

LOCALES = %w[nl fr de en].freeze

def check(condition, description)
  raise "Localization smoke failed: #{description}" unless condition

  puts "Localization smoke passed: #{description}"
end

def visit(session, path)
  session.get(path)
  check(session.response.status == 200, "#{path} renders (got #{session.response.status})")
  check(Nokogiri::HTML(session.response.body).at_css("html")&.[]("lang") == path.split("/")[1], "#{path} uses the requested language")
end

def redirected_visit(session, path, destination)
  session.get(path)
  check(session.response.redirect?, "#{path} redirects")
  check(URI.parse(session.response.location).path == destination, "#{path} redirects to #{destination}")
  session.follow_redirect!
  check(session.response.status == 200, "#{destination} renders after redirect")
end

def csrf(session)
  token = Nokogiri::HTML(session.response.body).at_css('meta[name="csrf-token"]')&.[]("content")
  check(token.present?, "CSRF token is present")
  CGI.unescapeHTML(token)
end

def browser
  ActionDispatch::Integration::Session.new(Rails.application).tap do |session|
    session.host! "i18n.lawrelay.invalid"
    session.https!
  end
end

def sign_in(session, locale, user, password, admin: false)
  path = admin ? "/#{locale}/admin/login" : "/#{locale}/session/new"
  visit(session, path)
  params = { authenticity_token: csrf(session), password: password }
  params[:email_address] = user.email_address unless admin
  session.post(admin ? "/#{locale}/admin/login" : "/#{locale}/session", params:)
  check(session.response.redirect?, "#{locale} #{admin ? 'admin' : 'member'} can sign in")
end

nonce = SecureRandom.hex(6)
password = "Smoke-password-#{nonce}!"
member = User.create!(first_name: "Locale", last_name: "Member", email_address: "member-#{nonce}@example.invalid", password:, email_verified_at: Time.current, locale: "nl")
firm = Firm.create!(name: Firm::INTERNAL_WORKSPACE_NAME, verification_status: "verified", verified_at: Time.current)
Membership.create!(user: member, firm:, role: "owner")
LawyerProfile.create!(user: member, bar_association: "OVB", bar_number: "SMOKE-#{nonce}", professional_email: member.email_address, directory_email: "directory-#{nonce}@example.invalid", verification_status: "verified", verified_at: Time.current, spoken_languages: LOCALES.map(&:upcase), practice_areas: [ "Civil" ])
billing_account = BillingAccount.create!(firm:, billing_email: member.email_address, status: "active", plan_key: "founding_beta", complimentary_access_until: 1.year.from_now)
invoice = Invoice.create!(billing_account:, status: "issued", subtotal_cents: 10_000, vat_rate_basis_points: 2100, issued_on: Date.current, due_on: 30.days.from_now)
assignment = Assignment.create!(kind: "court_replacement", assignment_subtype: "hearing", title: "Localization hearing #{nonce}", description: "Synthetic localization rendering record.", practice_area: "Civil", starts_at: 2.days.from_now, city: "Gent", court: "Smoke court", duration_minutes: 60, fee_cents: 25_000, status: "open", content_rules_accepted_at: Time.current, firm:, creator_user: member)
candidate = User.create!(first_name: "Candidate", last_name: "Locale", email_address: "candidate-#{nonce}@example.invalid", password:, email_verified_at: Time.current, locale: "nl")
candidate_firm = Firm.create!(name: Firm::INTERNAL_WORKSPACE_NAME, verification_status: "verified", verified_at: Time.current)
Membership.create!(user: candidate, firm: candidate_firm, role: "owner")
LawyerProfile.create!(user: candidate, bar_association: "OVB", bar_number: "SMOKE-CANDIDATE-#{nonce}",
  professional_email: candidate.email_address, verification_status: "verified", verified_at: Time.current)
check(candidate.marketplace_verified?, "synthetic mail recipient has current professional verification")
proposal = Proposal.create!(assignment:, user: candidate, firm: candidate_firm, rate_cents: 20_000, rate_kind: "fixed", message: "Synthetic proposal")
privacy_request = PrivacyRequest.create!(user: member, kind: "access_export", details: "Synthetic privacy request")
report = Report.create!(reporter_user: candidate, reportable: assignment, category: "other", details: "Synthetic report")
admin = User.create!(first_name: "Locale", last_name: "Administrator", email_address: "admin-#{nonce}@example.invalid", password:, email_verified_at: Time.current, locale: "nl", system_role: "admin")

anonymous = browser
LOCALES.each do |locale|
  [ "", "/privacy", "/terms", "/cookies", "/legal-notice", "/session/new", "/registration/new", "/passwords/new" ].each do |suffix|
    visit(anonymous, "/#{locale}#{suffix}")
  end
  redirected_visit(anonymous, "/#{locale}/pricing", "/#{locale}")
end

# Exercise the actual HTML fallback with a synthetic public-profile response.
# The isolated container never reaches the directory or creates an applicant.
signup_counts = [ User.count, Firm.count, LawyerProfile.count ]
signup_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/22222222-2222-4222-8222-222222222222"
signup_result = Directory::SignupProfile::Result.new(status: :ok, profile_url: signup_url,
  name: "Signup Preview", first_name: "Signup", last_name: "Preview", email_address: "signup-#{nonce}@example.invalid",
  profile_attributes: { spoken_languages: %w[NL FR], practice_areas: [ "Civil" ] })
original_signup = Directory::SignupProfile.method(:call)
Directory::SignupProfile.define_singleton_method(:call) { |**| signup_result }
begin
  LOCALES.each do |locale|
    Rails.cache.clear
    visit(anonymous, "/#{locale}/registration/new")
    anonymous.post("/#{locale}/registration/profile", params: { authenticity_token: csrf(anonymous),
      registration: { directory_profile_url: signup_url } })
    check(anonymous.response.status == 200, "#{locale} signup preview renders")
    document = Nokogiri::HTML(anonymous.response.body)
    check(document.at_css("html")&.[]("lang") == locale, "#{locale} signup preview uses the requested language")
    check(document.at_css("#registration_first_name")&.[]("value") == "Signup", "#{locale} signup name is prefilled")
    listed_email = document.at_css("[data-registration-profile-target='summaryEmail']")
    check(listed_email&.text&.strip == signup_result.email_address, "#{locale} listed email is shown")
    check(document.at_css("input[name='registration[email_address]']").nil?, "#{locale} signup has no editable email field")
    check(document.text.include?(I18n.t("signup_profile.confirm_email", locale:)), "#{locale} signup explains email confirmation")
    check(document.at_css("#registration_directory_preview_token")&.[]("value").present?, "#{locale} signup preview is signed")
    check(document.at_css("#registration_firm_name").nil? && document.at_css("#registration_enterprise_number").nil?, "#{locale} signup collects no company details")
    check(anonymous.response.headers["Cache-Control"] == "no-store", "#{locale} signup preview is not cached")
  end
ensure
  Directory::SignupProfile.define_singleton_method(:call, original_signup)
end
check([ User.count, Firm.count, LawyerProfile.count ] == signup_counts, "signup preview creates no account")

LOCALES.each do |locale|
  session = browser
  sign_in(session, locale, member, password)
    [ "", "/dashboard", "/assignments", "/assignments/#{assignment.id}", "/assignments/new", "/settings", "/settings/email", "/notifications", "/privacy_requests", "/privacy_requests/new" ].each do |suffix|
    visit(session, "/#{locale}#{suffix}")
  end
  redirected_visit(session, "/#{locale}/billing", "/#{locale}/dashboard")
end

# Invoice collection stays out of the marketplace.
candidate_session = browser
sign_in(candidate_session, "en", candidate, password)
LOCALES.each do |locale|
  visit(candidate_session, "/#{locale}/assignments/#{assignment.id}")
  check(!candidate_session.response.body.include?("invoice_enterprise_number"), "#{locale} assignment has no invoice-recipient fields")
end

# First MFA screen: it provisions a synthetic secret through the normal
# controller path. A separate signed-in session then exercises the challenge.
mfa_setup = browser
sign_in(mfa_setup, "nl", admin, password, admin: true)
LOCALES.each { |locale| visit(mfa_setup, "/#{locale}/admin/mfa/setup") }
admin.reload
secret = admin.admin_mfa_pending_secret
check(secret.present?, "MFA setup provisioned a secret")
mfa_setup.post("/nl/admin/mfa/setup", params: { authenticity_token: csrf(mfa_setup), mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now })
check(mfa_setup.response.redirect?, "MFA setup accepts a current TOTP")

mfa_challenge = browser
sign_in(mfa_challenge, "nl", admin, password, admin: true)
LOCALES.each { |locale| visit(mfa_challenge, "/#{locale}/admin/mfa/challenge") }
# The setup just consumed this TOTP. Give only the disposable user's replay
# history an older timestamp so a second authentication needs no wall-clock wait.
admin.reload.update!(admin_mfa_last_verified_at: 2.minutes.ago)
mfa_challenge.post("/nl/admin/mfa/challenge", params: { authenticity_token: csrf(mfa_challenge), mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now })
check(mfa_challenge.response.redirect?, "MFA challenge accepts a current TOTP")

LOCALES.each do |locale|
  [ "/admin/users", "/admin/users/#{member.to_param}", "/admin/registry-status", "/admin/verifications", "/admin/reports", "/admin/privacy_requests" ].each do |suffix|
    visit(mfa_challenge, "/#{locale}#{suffix}")
  end
  if ENV["LAWRELAY_RELEASE_MODE"] == "paid"
    visit(mfa_challenge, "/#{locale}/admin/founding_accesses")
  else
    redirected_visit(mfa_challenge, "/#{locale}/admin/founding_accesses", "/#{locale}/admin/users")
  end
end

admin_portal = browser
admin_portal.host! SiteHosts.admin_host
LOCALES.each do |locale|
  admin_portal.get("/#{locale}")
  check(URI.parse(admin_portal.response.location).path == "/#{locale}/admin/users", "#{locale} admin host opens administration")
  admin_portal.get("/#{locale}/admin/users")
  check(URI.parse(admin_portal.response.location).path == "/#{locale}/admin/login", "#{locale} admin host requires sign-in")
  visit(admin_portal, "/#{locale}/admin/login")
  check(admin_portal.response.body.include?("admin-site-header"), "#{locale} admin host uses the admin layout")
  admin.update!(locale:)
  check(PasswordsMailer.reset(admin).to.nil?, "#{locale} administrator password reset mail is suppressed")
  [ EmailVerificationMailer.verify(admin) ].each do |mail|
    [ mail.message.html_part, mail.message.text_part ].each do |part|
      check(part.decoded.include?("https://#{SiteHosts.admin_host}/#{locale}/"), "#{locale} admin account email uses the admin host")
    end
  end
end

mailers = {
  "email verification" => -> { EmailVerificationMailer.verify(member) },
  "password reset" => -> { PasswordsMailer.reset(member) },
  "directory verification" => -> { DirectoryVerificationMailer.confirm(member.lawyer_profile) },
  "new proposal" => -> { MarketplaceMailer.new_proposal(proposal) },
  "proposal accepted" => -> { MarketplaceMailer.proposal_accepted(proposal) },
  "proposal declined" => -> { MarketplaceMailer.proposal_declined(proposal) },
  "proposal withdrawn" => -> { MarketplaceMailer.proposal_withdrawn(proposal) },
  "assignment matched" => -> { MarketplaceMailer.assignment_matched(assignment, recipient: member) },
  "assignment completed" => -> { MarketplaceMailer.assignment_completed(assignment, recipient: candidate) },
  "assignment expired owner" => -> { MarketplaceMailer.assignment_expired(assignment, recipient: member) },
  "assignment expired candidate" => -> { MarketplaceMailer.assignment_expired(assignment, recipient: candidate) },
  "response deadline closed" => -> { MarketplaceMailer.response_deadline_closed(assignment, recipient: member) },
  "assignment cancelled" => -> { MarketplaceMailer.assignment_cancelled(assignment, locale: member.locale) }
}

LOCALES.each do |locale|
  member.update!(locale:)
  candidate.update!(locale:)
  mailers.each do |name, build|
    message = build.call.message
    check(message.html_part.present? && message.text_part.present?, "#{locale} #{name} has HTML and plain-text bodies")
    [ message.html_part, message.text_part ].each do |part|
      body = part.decoded
      check(body.include?("https://i18n.lawrelay.invalid/#{locale}/") && !body.match?(/translation missing/i), "#{locale} #{name} #{part.mime_type} is localized")
    end
  end
end

member_security = browser
sign_in(member_security, "en", member, password)
LOCALES.each { |locale| visit(member_security, "/#{locale}/settings/two-factor") }
member_security.post("/en/settings/two-factor/begin-setup", params: { authenticity_token: csrf(member_security), current_password: password })
check(member_security.response.redirect?, "member two-factor setup requires password confirmation")
LOCALES.each do |locale|
  visit(member_security, "/#{locale}/settings/two-factor/setup")
  check(Nokogiri::HTML(member_security.response.body).at_css("img.mfa-qr")&.[]("src")&.start_with?("data:image/png;base64,"), "#{locale} member QR is local")
end
member.reload
member_security.post("/en/settings/two-factor/enable", params: { authenticity_token: csrf(member_security), mfa_code: ROTP::TOTP.new(member.two_factor_pending_secret, issuer: "LawRelay").now })
check(member_security.response.status == 200, "member two-factor enrollment succeeds")
recovery_codes = Nokogiri::HTML(member_security.response.body).css(".recovery-codes code").map(&:text)
check(recovery_codes.length == 10, "member sees ten one-time recovery codes")
LOCALES.each { |locale| visit(member_security, "/#{locale}/settings/two-factor") }
member_security.delete("/en/session", params: { authenticity_token: csrf(member_security) })
sign_in(member_security, "en", member, password)
LOCALES.each { |locale| visit(member_security, "/#{locale}/settings/two-factor/challenge") }
member_security.post("/en/settings/two-factor/verify", params: { authenticity_token: csrf(member_security), recovery_code: recovery_codes.first })
check(member_security.response.redirect?, "member recovery code verifies sign-in")
check(member.reload.two_factor_recovery_codes_remaining == 9, "member recovery code is consumed")

member.lawyer_profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111", directory_name: member.full_name)
original_import = Directory::ProfileImport.method(:call)
Directory::ProfileImport.define_singleton_method(:call) do |**|
  Directory::ProfileImport::Result.new(status: :ok, profile_attributes: { spoken_languages: %w[NL FR] })
end
begin
  LOCALES.each do |locale|
    # Independent render cases must not share the account's import rate limit.
    Rails.cache.clear
    visit(member_security, "/#{locale}/settings")
    check(Nokogiri::HTML(member_security.response.body).at_css("button[value='import_profile']"), "#{locale} linked profile import button renders")
    member_security.patch("/#{locale}/settings", params: { authenticity_token: csrf(member_security),
      settings_action: "import_profile", profile: { availability_note: "Synthetic unsaved note" } })
    check(member_security.response.status == 200, "#{locale} profile import preview renders (got #{member_security.response.status})")
    check(member.lawyer_profile.reload.availability_note != "Synthetic unsaved note" && member.primary_firm.phone.nil?, "#{locale} profile import did not save changes")
  end
ensure
  Directory::ProfileImport.define_singleton_method(:call, original_import)
end

profile = member.reload.lawyer_profile
profile.update!(verification_status: "pending", verified_at: nil, directory_profile_id: nil,
  directory_name: nil, directory_email: nil, directory_checked_at: nil, directory_email_verified_at: nil)
failed_lookup = Object.new
failed_lookup.define_singleton_method(:call) do |**|
  Directory::AdvocaatBeProfileLookup::Result.new(status: :name_mismatch,
    profile_id: nil, source_url: nil, name: nil, email: nil, checked_at: nil)
end
Directory::Verification.request!(user: member, lookup: failed_lookup)
LOCALES.each do |locale|
  visit(member_security, "/#{locale}/verification_status")
  check(member_security.response.body.include?(I18n.t("directory_feedback.failures.name_mismatch", locale:)), "#{locale} directory feedback is localized")
end
profile.reload.update!(directory_profile_id: "11111111-1111-4111-8111-111111111111", directory_name: member.full_name,
  directory_email: "official-#{nonce}@example.invalid", directory_checked_at: Time.current)
LOCALES.each do |locale|
  visit(member_security, "/#{locale}/verification_status")
  label = I18n.t("directory_feedback.resend_confirmation", locale:)
  check(Nokogiri::HTML(member_security.response.body).css("button").any? { |button| button.text == label }, "#{locale} official-email resend is available")
  visit(member_security, "/#{locale}/verification/email-access")
end

profile.update!(email_review_status: "pending", email_review_email_address: member.email_address,
  email_review_requested_at: 1.minute.ago, directory_checked_at: Time.current)
LOCALES.each do |locale|
  visit(member_security, "/#{locale}/verification_status")
  visit(mfa_challenge, "/#{locale}/admin/email-reviews")
  visit(mfa_challenge, "/#{locale}/admin/email-reviews/#{member.to_param}")
end

%w[approved rejected].each do |status|
  profile.update!(email_review_status: status, email_reviewed_at: Time.current,
    email_reviewed_by_user: admin, email_review_note: "Private synthetic identity check",
    email_review_identity_digest: profile.email_review_current_identity_digest)
  LOCALES.each do |locale|
    member.update!(locale:)
    visit(member_security, "/#{locale}/verification_status")
    visit(mfa_challenge, "/#{locale}/admin/email-reviews/#{member.to_param}")
    message = EmailAccessReviewMailer.decision(profile.reload).message
    check(message.html_part.present? && message.text_part.present?, "#{locale} email review #{status} has both bodies")
    [ message.html_part, message.text_part ].each do |part|
      body = part.decoded
      check(body.include?("https://i18n.lawrelay.invalid/#{locale}/") && !body.match?(/translation missing/i), "#{locale} email review #{status} #{part.mime_type} is localized")
      check(!body.include?(profile.email_review_note), "#{locale} email review #{status} keeps internal notes private")
    end
  end
end

target = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == profile.id }
check(target.present?, "synthetic directory target is available")
registry_check = RegistryStatusCheck.new(source: "directory", target_digest: target.digest, lawyer_profile: profile)
registry_check.record_result!(outcome: "not_listed", checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
registry_run = RegistryStatusRun.create!(run_on: Date.current, status: "completed", completed_at: Time.current,
  findings: [ registry_check.finding_snapshot ])
LOCALES.each do |locale|
  admin.update!(locale:)
  visit(mfa_challenge, "/#{locale}/admin/registry-status")
  message = RegistryStatusMailer.daily_alert(registry_run).message
  check(message.html_part.present? && message.text_part.present?, "#{locale} registry summary has both bodies")
  [ message.html_part, message.text_part ].each do |part|
    body = part.decoded
    check(body.include?("/#{locale}/admin/registry-status") && !body.match?(/translation missing/i), "#{locale} registry summary is localized")
    check(!body.include?(member.email_address) && !body.include?(profile.directory_email), "#{locale} registry summary keeps member addresses private")
  end
end

member.update!(email_verified_at: nil)
profile.update!(email_review_status: nil)
AuditEvent.create!(auditable: member, actor_user: admin, action: "user.verification_resent", metadata: { channels: [ "account_email" ] })
LOCALES.each do |locale|
  visit(mfa_challenge, "/#{locale}/admin/users/#{member.to_param}")
  button = Nokogiri::HTML(mfa_challenge.response.body).css("button").find do |candidate|
    candidate.text == I18n.t("admin.users.verification_delivery.action", locale:)
  end
  check(button.present?, "#{locale} pending verification has a localized admin resend button")
end

check(ActionMailer::Base.deliveries.empty?, "no email was delivered")
puts "Localized production rendering completed with only disposable synthetic records (invoice #{invoice.id}, request #{privacy_request.id}, report #{report.id})."
