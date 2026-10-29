require "test_helper"
require "rake"

Rails.application.load_tasks

class LawrelayTasksTest < ActiveSupport::TestCase
  test "protected password recovery revokes sessions and preserves administrator email and MFA" do
    user = recovery_admin
    secret = user.begin_admin_mfa_setup!
    user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    original_mfa = user.admin_mfa_secret_ciphertext
    original_email = user.email_address
    user.sessions.create!

    with_password_input("replacement-password1234", "replacement-password1234") do
      assert_difference("AuditEvent.where(action: 'admin.password_changed').count", 1) do
        capture_io { invoke_task("lawrelay:set_admin_password", user.email_address) }
      end
    end

    assert user.reload.authenticate("replacement-password1234")
    assert_not user.authenticate("password1234")
    assert_empty user.sessions
    assert_equal original_email, user.email_address
    assert_equal original_mfa, user.admin_mfa_secret_ciphertext
    assert_predicate user, :admin_mfa_configured?
    event = AuditEvent.where(auditable: user).last
    assert_equal "rake", event.metadata["source"]
    assert_nil event.actor_user
    assert_not_includes event.metadata.to_json, "replacement-password1234"
  end

  test "protected password recovery rejects members inactive administrators and noninteractive input" do
    member = users(:one)
    inactive = recovery_admin
    inactive.update!(suspended_at: Time.current)
    [ member, inactive ].each do |user|
      assert_no_difference "AuditEvent.count" do
        capture_io { assert_raises(SystemExit) { invoke_task("lawrelay:set_admin_password", user.email_address) } }
      end
      assert user.reload.authenticate("password") if user == member
    end

    active = recovery_admin(email: "interactive-recovery@example.test")
    with_password_input("unused-password1234", "unused-password1234", tty: false) do
      capture_io { assert_raises(SystemExit) { invoke_task("lawrelay:set_admin_password", active.email_address) } }
    end
    assert active.reload.authenticate("password1234")
  end

  test "protected password recovery rejects mismatched short and invalid passwords without changes" do
    user = recovery_admin
    session = user.sessions.create!
    original_digest = user.password_digest
    [ [ "replacement-password1234", "different-password1234" ], [ "short", "short" ], [ "", "" ],
      [ "x" * 73, "x" * 73 ], [ "€" * 25, "€" * 25 ] ].each do |values|
      with_password_input(*values) do
        assert_no_difference "AuditEvent.count" do
          capture_io { assert_raises(SystemExit) { invoke_task("lawrelay:set_admin_password", user.email_address) } }
        end
      end
      assert_equal original_digest, user.reload.password_digest
      assert Session.exists?(session.id)
    end
  end

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

  def invoke_task(name = "lawrelay:promote_admin", *arguments)
    task = Rake::Task[name]
    task.reenable
    task.invoke(*arguments)
  end

  def recovery_admin(email: "password-recovery-admin@example.test")
    User.create!(email_address: email, password: "password1234", first_name: "Recovery", last_name: "Admin",
      locale: "en", system_role: "admin", email_verified_at: Time.current)
  end

  def with_password_input(*values, tty: true)
    require "io/console"
    original_getpass = STDIN.method(:getpass)
    original_tty = STDIN.method(:tty?)
    # Copies keep the task's secret cleanup from changing test inputs.
    inputs = values.map(&:dup)
    STDIN.define_singleton_method(:getpass) { |_prompt| inputs.shift }
    STDIN.define_singleton_method(:tty?) { tty }
    yield
  ensure
    STDIN.define_singleton_method(:getpass, original_getpass) if original_getpass
    STDIN.define_singleton_method(:tty?, original_tty) if original_tty
  end

  def with_env(values)
    original = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
