require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::ManualActivationTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @account = create_matched_account("manual-member")
    @user, @profile = @account.user, @account.profile
    @admin = create_marketplace_account(prefix: "manual-operator", system_role: "admin").user
    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    @session = @user.sessions.create!
  end

  test "explicit approval grants access without claiming email confirmation or sending mail" do
    original_credentials = @user.attributes.slice("password_digest", "admin_mfa_secret_ciphertext", "admin_mfa_enabled_at",
      "two_factor_secret_ciphertext", "two_factor_enabled_at")

    assert_no_enqueued_jobs do
      assert_no_emails do
        result = approve
        assert result.success?, result.status.to_s
      end
    end

    assert @user.reload.marketplace_verified?
    assert_nil @user.email_verified_at
    assert_nil @profile.reload.directory_email_verified_at
    assert @profile.manual_activation_valid?
    assert @account.firm.reload.verified?
    assert @profile.verified?
    assert_equal @admin.id, @profile.manual_activation_approved_by_user_id
    assert_equal original_credentials, @user.attributes.slice(*original_credentials.keys)
    assert Session.exists?(@session.id)

    approval = AuditEvent.find_by!(auditable: @profile, action: "verification.approved")
    assert_equal @admin.id, approval.actor_user_id
    assert_equal "manual_activation", approval.metadata.fetch("method")
    assert_equal false, approval.metadata.fetch("email_link_confirmed")
    assert_equal false, approval.metadata.fetch("email_sent")
    assert_equal @admin.id, AuditEvent.find_by!(auditable: @profile, action: "verification.directory_activated").actor_user_id
    assert_not AuditEvent.where(auditable: @profile, action: "verification.directory_email_confirmed").exists?
    assert_no_difference "AuditEvent.count" do
      assert approve.success?, "repeating the same approval must be idempotent"
    end
  end

  test "ordinary unconfirmed accounts still cannot access assignments" do
    assert_not @user.marketplace_verified?
    assert_equal :pending, Directory::Verification.activate_if_ready!(user: @user).status
    assert_nil @profile.reload.manual_activation_approved_at
    assert_not @user.reload.marketplace_verified?
  end

  test "approval requires an active administrator with configured MFA" do
    [ nil, @user ].each do |actor|
      assert_refused(:protected) { approve(actor:) }
    end
    @admin.update!(admin_mfa_enabled_at: nil)
    assert_refused(:protected) { approve }
    @admin.update!(admin_mfa_enabled_at: Time.current, suspended_at: Time.current)
    assert_refused(:protected) { approve }
  end

  test "a reason and the exact reviewed identity are required" do
    assert_refused(:note_required) { approve(note: " ") }
    assert_refused(:note_required) { approve(note: "x" * 2_001) }
    assert_refused(:stale) { approve(identity_digest: "previous identity") }
    assert_refused(:stale) { approve(identity_digest: "") }
  end

  test "suspended rejected erased and administrator accounts remain protected" do
    @user.update!(suspended_at: Time.current)
    assert_refused(:protected) { approve }
    @user.update!(suspended_at: nil, erased_at: Time.current)
    assert_refused(:protected) { approve }
    @user.update!(erased_at: nil, system_role: "admin")
    assert_refused(:protected) { approve }
    @user.update!(system_role: "member")
    [ @profile, @account.firm ].each do |record|
      %w[rejected suspended].each do |status|
        record.update!(verification_status: status)
        assert_refused(:protected) { approve }
        record.update!(verification_status: "pending")
      end
    end
  end

  test "a valid matching official profile and account address are required" do
    original = @profile.attributes.slice("directory_profile_url", "directory_name", "directory_email", "directory_checked_at")
    [
      { directory_profile_url: "https://unrelated.example.test/profile" },
      { directory_name: "A Different Lawyer" },
      { directory_email: "different@example.test" },
      { directory_checked_at: nil }
    ].each do |changes|
      @profile.update!(changes)
      assert_refused(:directory_required) { approve }
      @profile.update!(original)
    end
  end

  test "pending rejected and stale email reviews cannot be bypassed" do
    %w[pending rejected approved].each do |status|
      @profile.update!(email_review_status: status)
      assert_refused(:review_required) { approve }
    end
  end

  test "approved directory identities remain exclusive across all claim paths" do
    assert approve.success?
    other = create_matched_account("other-manual-member")
    other.profile.update!(directory_profile_id: @profile.directory_profile_id,
      directory_profile_url: @profile.directory_profile_url)

    result = approve(user: other.user, identity_digest: other.profile.email_review_current_identity_digest)
    assert_equal :claimed, result.status
    assert_nil other.profile.reload.manual_activation_approved_at
    assert_raises ActiveRecord::RecordNotUnique do
      other.profile.update_columns(directory_email_verified_at: Time.current)
    end
    assert_raises ActiveRecord::RecordNotUnique do
      other.profile.update_columns(manual_activation_approved_at: Time.current)
    end
    other.profile.reload

    evidence = directory_evidence(other.user)
    lookup = Struct.new(:evidence) { def call(**) = evidence }.new(evidence)
    assert_equal :already_claimed, Directory::Verification.request!(user: other.user, lookup:).status
  end

  test "account identity changes revoke manual approval without sending email" do
    [ { first_name: "Changed" }, { last_name: "Changed" }, { email_address: "changed@example.test" } ].each do |changes|
      account = create_matched_account("manual-identity")
      assert approve(user: account.user, identity_digest: account.profile.email_review_current_identity_digest).success?
      assert_no_enqueued_jobs { account.user.update!(changes) }
      assert_not account.user.reload.marketplace_verified?
      assert_nil account.profile.reload.manual_activation_approved_at
    end
  end

  test "official identity changes revoke manual approval and release the stale manual claim" do
    [
      { directory_name: "Changed Official Name" }, { directory_email: "changed-listed@example.test" },
      { directory_profile_id: SecureRandom.uuid },
      { directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}" }
    ].each do |changes|
      account = create_matched_account("manual-source")
      assert approve(user: account.user, identity_digest: account.profile.email_review_current_identity_digest).success?
      assert_no_enqueued_jobs { account.profile.update!(changes) }
      assert_not account.user.reload.marketplace_verified?
      assert_nil account.profile.reload.manual_activation_approved_at
      assert_nil account.profile.manual_activation_identity_digest
    end
  end

  test "a refresh of the same official identity preserves manual approval without an email" do
    assert approve.success?
    evidence = directory_evidence(@user)
    lookup = Struct.new(:evidence) { def call(**) = evidence }.new(evidence)

    assert_no_enqueued_jobs do
      assert Directory::Verification.request!(user: @user.reload, lookup:).success?
    end
    assert @profile.reload.manual_activation_valid?
    assert @user.reload.marketplace_verified?
    assert_nil @user.email_verified_at
    assert_nil @profile.directory_email_verified_at
  end

  test "the digest fails closed even when an identity change bypasses callbacks" do
    assert approve.success?
    @user.update_columns(first_name: "Changed outside callbacks")
    assert_not @user.reload.marketplace_verified?
    assert_not @profile.reload.manual_activation_valid?
  end

  test "an activation failure rolls back the manual approval and audit records" do
    unavailable = Directory::Verification::Result.new(status: :pending, profile: @profile)
    original = Directory::Verification.method(:activate_if_ready!)
    Directory::Verification.define_singleton_method(:activate_if_ready!) { |**| unavailable }
    assert_refused(:unavailable) { approve }
    assert_not @user.reload.marketplace_verified?
  ensure
    Directory::Verification.define_singleton_method(:activate_if_ready!, original) if original
  end

  private

  def create_matched_account(prefix)
    account = create_marketplace_account(prefix:, verified: false, email_verified: false)
    profile_id = SecureRandom.uuid
    account.profile.update!(directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: account.user.full_name, directory_email: account.user.email_address,
      directory_checked_at: Time.current, directory_identity_digest: SecureRandom.hex(32))
    account
  end

  def approve(user: @user, actor: @admin, note: "Operator approved access after direct professional contact; no email link confirmed.", identity_digest: @profile.reload.email_review_current_identity_digest)
    Admin::ManualActivation.call(user:, actor:, note:, identity_digest:)
  end

  def assert_refused(status)
    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs do
        result = yield
        assert_not result.success?
        assert_equal status, result.status
      end
    end
    assert_nil @profile.reload.manual_activation_approved_at
    assert_nil @user.reload.email_verified_at
    assert_nil @profile.directory_email_verified_at
  end

  def directory_evidence(user)
    Directory::AdvocaatBeProfileLookup::Result.new(status: :ok, profile_id: @profile.directory_profile_id,
      source_url: @profile.directory_profile_url, name: user.full_name, email: user.email_address, checked_at: Time.current)
  end
end
