namespace :lawrelay do
  desc "Set a named administrator password through a protected interactive terminal"
  task :set_admin_password, [ :email ] => :environment do |_task, arguments|
    require "io/console"

    email = (arguments[:email].presence || ENV["EMAIL"]).to_s.strip.downcase
    abort "Provide EMAIL=admin@example.com or lawrelay:set_admin_password[email]." if email.blank?
    user = User.find_by(email_address: email)
    abort "No active administrator exists for that address." unless user&.system_admin? && user.active?
    abort "Use a protected interactive terminal for administrator password recovery." unless STDIN.tty?

    password = STDIN.getpass("New administrator password: ")
    confirmation = STDIN.getpass("Confirm administrator password: ")
    abort "Passwords do not match." unless password == confirmation
    abort "Use a password of at least 12 characters." if password.blank? || password.length < 12
    abort "Password is too long (maximum 72 bytes)." if password.bytesize > 72

    user.with_lock do
      abort "No active administrator exists for that address." unless user.system_admin? && user.active?

      user.update!(password:, password_confirmation: confirmation)
      user.sessions.destroy_all
      AuditEvent.create!(auditable: user, firm: user.primary_firm,
        action: "admin.password_changed", metadata: { source: "rake" })
    end
    puts "Administrator password updated; sessions signed out. MFA is unchanged."
  rescue ActiveRecord::RecordInvalid
    abort "The administrator password could not be updated. No changes were saved."
  ensure
    password&.clear
    confirmation&.clear
  end

  desc "Promote an existing email-verified user to system administrator (EMAIL=admin@example.com)"
  task :promote_admin, [ :email ] => :environment do |_task, arguments|
    email = (arguments[:email].presence || ENV["EMAIL"]).to_s.strip.downcase
    abort "Provide EMAIL=verified-lawyer@example.com or lawrelay:promote_admin[email]." if email.blank?

    user = User.find_by(email_address: email)
    abort "No LawRelay user exists for #{email}." unless user
    abort "#{email} must verify its email address before it can become an administrator." unless user.email_verified?

    if user.system_admin?
      puts "#{email} is already a system administrator."
      next
    end

    User.transaction do
      user.update!(system_role: "admin")
      AuditEvent.create!(
        auditable: user,
        firm: user.primary_firm,
        action: "admin.promoted",
        metadata: { "source" => "rake", "email" => user.email_address }
      )
    end

    puts "Promoted #{email} to system administrator. Record the operator and time in the access register."
  end

  desc "Reset TOTP MFA for a named system administrator (EMAIL=admin@example.com)"
  task :reset_admin_mfa, [ :email ] => :environment do |_task, arguments|
    email = (arguments[:email].presence || ENV["EMAIL"]).to_s.strip.downcase
    abort "Provide EMAIL=admin@example.com or lawrelay:reset_admin_mfa[email]." if email.blank?

    user = User.find_by(email_address: email)
    abort "No LawRelay user exists for #{email}." unless user
    abort "#{email} is not a system administrator." unless user.system_admin?

    User.transaction do
      user.reset_admin_mfa!
      user.sessions.update_all(admin_mfa_verified_at: nil, admin_mfa_challenged_at: nil, updated_at: Time.current)
      AuditEvent.create!(
        auditable: user,
        firm: user.primary_firm,
        action: "admin.mfa_reset",
        metadata: { "source" => "rake", "email" => user.email_address }
      )
    end

    puts "Reset MFA for #{email}. The administrator must set up a new authenticator before using administration."
  end

  desc "Confirm one manual bank/Peppol payment (PAYMENT_ID=123 ACTOR_EMAIL=admin@example.com PAYMENT_REFERENCE=...)"
  task confirm_manual_payment: :environment do
    payment_id = ENV["PAYMENT_ID"].to_s
    actor_email = ENV["ACTOR_EMAIL"].to_s.strip.downcase
    payment_reference = ENV["PAYMENT_REFERENCE"].to_s
    abort "Provide PAYMENT_ID, ACTOR_EMAIL, and PAYMENT_REFERENCE." if payment_id.blank? || actor_email.blank? || payment_reference.blank?

    payment = BillingPayment.find_by(id: payment_id)
    abort "No billing payment exists with ID #{payment_id}." unless payment

    actor = User.find_by(email_address: actor_email)
    abort "No LawRelay user exists for #{actor_email}." unless actor

    result = Billing::ManualPaymentConfirmationService.new(
      payment:,
      actor_user: actor,
      payment_reference:
    ).call

    if result.activated
      puts "Confirmed payment #{payment.id}; subscription #{result.subscription.id} is active until #{result.subscription.current_period_ends_at.iso8601}."
    else
      puts "Payment #{payment.id} was already confirmed; no billing period was added."
    end
  rescue Billing::ManualPaymentConfirmationService::InvalidConfirmation => error
    abort error.message
  end
end
