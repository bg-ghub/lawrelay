require "test_helper"
require "rake"

Rails.application.load_tasks

class LawrelayTasksTest < ActiveSupport::TestCase
  test "promote_admin promotes an email-verified user and records an audit event" do
    user = User.create!(
      email_address: "bootstrap-admin@example.test",
      password: "password1234",
      first_name: "Bootstrap",
      last_name: "Admin",
      locale: "en",
      email_verified_at: Time.current
    )

    with_env("EMAIL" => user.email_address) do
      assert_difference("AuditEvent.count", 1) do
        invoke_task
      end
    end

    assert user.reload.system_admin?
    event = AuditEvent.order(:created_at).last
    assert_equal "admin.promoted", event.action
    assert_nil event.actor_user
    assert_equal "rake", event.metadata.fetch("source")
  end

  test "promote_admin refuses an unverified user" do
    user = User.create!(
      email_address: "unverified-admin@example.test",
      password: "password1234",
      first_name: "Unverified",
      last_name: "Admin",
      locale: "en"
    )

    with_env("EMAIL" => user.email_address) do
      assert_raises(SystemExit) { invoke_task }
    end

    assert_not user.reload.system_admin?
    assert_equal 0, AuditEvent.where(auditable: user).count
  end

  test "reset_admin_mfa clears enrollment and records an audited recovery" do
    user = User.create!(
      email_address: "recover-admin@example.test",
      password: "password1234",
      first_name: "Recovery",
      last_name: "Admin",
      locale: "en",
      system_role: "admin",
      email_verified_at: Time.current
    )
    secret = user.begin_admin_mfa_setup!
    user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    session = user.sessions.create!
    session.mark_admin_mfa_verified!

    with_env("EMAIL" => user.email_address) do
      assert_difference("AuditEvent.where(action: 'admin.mfa_reset').count", 1) do
        invoke_task("lawrelay:reset_admin_mfa")
      end
    end

    assert_not user.reload.admin_mfa_configured?
    assert_nil session.reload.admin_mfa_verified_at
  end

  private

  def invoke_task(name = "lawrelay:promote_admin")
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  def with_env(values)
    original = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
