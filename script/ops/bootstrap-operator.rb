# Run with bin/rails runner after the production hostname and email are live.
# Set the initial password through the protected set_admin_password task.
abort "Operator bootstrap is for production only." unless Rails.env.production?

email = ENV.fetch("OPERATOR_EMAIL").strip.downcase
first_name = ENV.fetch("OPERATOR_FIRST_NAME")
last_name = ENV.fetch("OPERATOR_LAST_NAME")
user = User.find_by(email_address: email)

if user
  abort "An existing member account cannot be promoted by initial bootstrap." unless user.system_admin?
  puts "Operator administrator already exists; no account or password was changed."
else
  abort "An administrator already exists. Use the audited promotion task instead." if User.where(system_role: "admin").exists?

  User.transaction do
    user = User.create!(
      first_name:, last_name:, email_address: email,
      password: SecureRandom.base64(48), locale: "nl",
      email_verified_at: Time.current, system_role: "admin"
    )
    AuditEvent.create!(
      auditable: user, action: "admin.bootstrapped",
      metadata: { source: "production_operator_setup" }
    )
  end
  puts "Operator administrator created. Set its password with lawrelay:set_admin_password[email] in a protected interactive terminal. MFA is required before administration."
end
