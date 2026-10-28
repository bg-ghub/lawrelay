require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::UserManagementTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  setup do
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @account = create_marketplace_account(prefix: "managed")
    @user = @account.user
    @manager = Admin::UserManagement.new(actor: @admin, user: @user)
  end

  test "suspension revokes sessions and access without changing shared professional verification" do
    @user.sessions.create!
    assert_difference "AuditEvent.count", 1 do
      assert @manager.suspend!(reason: "Reported account compromise")
    end

    assert @user.reload.suspended?
    assert_not @user.marketplace_verified?
    assert_empty @user.sessions
    assert @account.profile.reload.verified?
    assert @account.firm.reload.verified?
    event = AuditEvent.where(auditable: @user).last
    assert_equal "admin.user_suspended", event.action
    assert_equal @admin, event.actor_user
    assert_equal "Reported account compromise", event.metadata["reason"]
    assert_no_difference "AuditEvent.count" do
      assert_not @manager.suspend!(reason: "Duplicate request")
    end
  end

  test "restoration removes only the account hold and does not grant pending verification" do
    @account.profile.update!(verification_status: "pending", verified_at: nil)
    @manager.suspend!(reason: "Investigation")
    @user.sessions.create!

    assert_difference "AuditEvent.count", 1 do
      assert @manager.restore!(reason: "Investigation completed")
    end
    assert @user.reload.active?
    assert_nil @user.suspension_reason
    assert_empty @user.sessions
    assert_not @user.marketplace_verified?
    assert_equal "pending", @account.profile.reload.verification_status
    assert_no_difference "AuditEvent.count" do
      assert_not @manager.restore!(reason: "Repeated restoration")
    end
  end

  test "state changes require a bounded nonempty reason before any mutation" do
    [ nil, "  ", "x" * 2_001 ].each do |reason|
      assert_no_difference "AuditEvent.count" do
        assert_raises(Admin::UserManagement::InvalidAction) { @manager.suspend!(reason:) }
      end
      assert @user.reload.active?
    end
  end

  test "administrator targets are protected including the operator's own account" do
    another_admin = users(:two)
    another_admin.update!(system_role: "admin")
    [ @admin, another_admin ].each do |user|
      manager = Admin::UserManagement.new(actor: @admin, user:)
      assert_raises(Admin::UserManagement::InvalidAction) { manager.update!(first_name: "Changed") }
      assert_raises(Admin::UserManagement::InvalidAction) { manager.suspend!(reason: "Blocked") }
      assert_raises(Admin::UserManagement::InvalidAction) { manager.restore!(reason: "Blocked") }
      assert_raises(Admin::UserManagement::InvalidAction) { manager.revoke_sessions!(reason: "Blocked") }
      assert user.reload.active?
    end
  end

  test "ordinary or suspended administrators cannot invoke the management service" do
    ordinary_actor = users(:two)
    assert_raises(Admin::UserManagement::InvalidAction) do
      Admin::UserManagement.new(actor: ordinary_actor, user: @user).suspend!(reason: "Not allowed")
    end
    @admin.update!(suspended_at: Time.current)
    assert_raises(Admin::UserManagement::InvalidAction) { @manager.suspend!(reason: "Not allowed") }
    assert @user.reload.active?
  end

  test "identity changes clear old directory proof revoke sessions and require a new email proof" do
    @account.profile.update!(
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @user.full_name, directory_email: @user.email_address,
      directory_checked_at: Time.current, directory_email_verified_at: Time.current,
      directory_identity_digest: "synthetic-directory-evidence"
    )
    @user.sessions.create!
    token = @user.email_verification_token
    result = @manager.update!(email_address: "replacement@example.test", system_role: "admin", email_verified_at: Time.current)

    assert result.changed
    assert result.identity_changed
    assert result.email_changed
    assert_nil @user.reload.email_verified_at
    assert_equal "member", @user.system_role
    assert_empty @user.sessions
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { User.find_by_email_verification_token!(token) }
    profile = @account.profile.reload
    assert_nil profile.directory_profile_id
    assert_nil profile.directory_identity_digest
    assert_nil profile.directory_email_verified_at
    assert profile.directory_profile_url.present?
    assert_equal "pending", profile.verification_status
    assert @account.firm.reload.verified?
    metadata = AuditEvent.where(auditable: @user).last.metadata
    assert_equal [ "email_address" ], metadata["changed_fields"]
    assert_not_includes metadata.to_json, "replacement@example.test"
  end

  test "name edits cannot reopen a protected professional profile" do
    @account.profile.update!(verification_status: "rejected")
    @manager.update!(first_name: "Changed")

    assert_equal "rejected", @account.profile.reload.verification_status
    assert @user.reload.email_verified?
  end

  test "ordinary edits do not change professional status and no-op edits add no audit" do
    result = @manager.update!(locale: "fr")
    assert result.changed
    assert_not result.identity_changed
    assert @account.profile.reload.verified?
    assert_no_difference "AuditEvent.count" do
      assert_not @manager.update!(locale: "fr").changed
    end
  end

  test "invalid account edits roll back directory proof and preserve sessions" do
    @user.sessions.create!
    assert_no_difference "AuditEvent.count" do
      assert_raises(ActiveRecord::RecordInvalid) { @manager.update!(email_address: "not-an-email") }
    end
    assert @user.reload.email_verified?
    assert @account.profile.reload.verified?
    assert_equal 1, @user.sessions.count
  end

  test "session revocation requires a reason and is idempotent" do
    @user.sessions.create!
    assert @manager.revoke_sessions!(reason: "User requested sign-out on other devices")
    assert_empty @user.sessions
    assert @user.reload.active?
    assert_no_difference "AuditEvent.count" do
      assert_not @manager.revoke_sessions!(reason: "Same request")
    end
  end
end
