require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Accounts::EmailAccessTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "review-member", verified: false, email_verified: false)
    @user = @account.user
    @profile = @account.profile
    @directory_email = @user.email_address
    @directory_id = SecureRandom.uuid
    attach_directory
    @session = @user.sessions.create!
    @other_session = @user.sessions.create!
    @admin = create_marketplace_account(prefix: "review-operator", system_role: "admin").user
    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    @working_email = "working-#{SecureRandom.hex(5)}@example.test"
  end

  test "request changes sign-in email and keeps only the current session without granting access" do
    token = @user.email_verification_token
    result = request_review

    assert_predicate result, :success?
    assert result.request_created
    assert_equal @working_email, @user.reload.email_address
    assert_nil @user.email_verified_at
    assert_nil User.find_by_token_for(:email_verification, token)
    assert_equal [ @session.id ], @user.sessions.pluck(:id)
    assert_equal "pending", @profile.reload.email_review_status
    assert_equal @working_email, @profile.professional_email
    assert_nil @profile.directory_email_verified_at
    assert_not @profile.directory_confirmation_required?
    assert_not @user.marketplace_verified?
    assert_equal 1, AuditEvent.where(auditable: @profile, action: "email_access.requested").count
  end

  test "wrong password foreign session and administrator requests cannot mutate the account" do
    old_email = @user.email_address
    assert_not request_review(password: "wrong").success?
    foreign = create_marketplace_account(prefix: "foreign-review").user.sessions.create!
    assert_not request_review(current_session: foreign).success?
    @user.update!(system_role: "admin")
    assert_not request_review.success?
    assert_equal old_email, @user.reload.email_address
    assert_nil @profile.reload.email_review_status
    assert Session.exists?(@other_session.id)
  end

  test "a suspended or previously rejected profile cannot use the fallback to reset protection" do
    @profile.update!(verification_status: "rejected")
    assert_not request_review.success?
    assert_equal "rejected", @profile.reload.verification_status
    @profile.update!(verification_status: "pending")
    @user.update!(suspended_at: Time.current)
    assert_not request_review.success?
    assert_nil @profile.reload.email_review_status
  end

  test "duplicate pending submission is idempotent and rejected requests can be resubmitted" do
    assert request_review.success?
    created_at = @profile.reload.email_review_requested_at
    result = request_review
    assert result.success?
    assert_not result.request_created
    assert_equal created_at, @profile.reload.email_review_requested_at
    assert_equal 1, AuditEvent.where(auditable: @profile, action: "email_access.requested").count
    assert review(decision: "reject").success?
    assert_equal @profile.email_review_current_identity_digest, @profile.reload.email_review_identity_digest
    assert request_review.success?
    assert_equal "pending", @profile.reload.email_review_status
    assert_nil @profile.email_reviewed_at
    assert_nil @profile.email_review_note
  end

  test "an already confirmed working sign-in address can request review without losing its email proof" do
    @user.update!(email_address: @working_email, email_verified_at: Time.current)
    @user.update!(email_verified_at: Time.current)
    assert request_review.success?
    assert @user.reload.email_verified?
    assert @profile.reload.email_review_pending?
    assert_not @user.marketplace_verified?
  end

  test "confirmation alone and legacy verified flags do not bypass a pending review" do
    assert request_review.success?
    @user.update!(email_verified_at: Time.current)
    @profile.update!(verification_status: "verified", verified_at: Time.current)
    @account.firm.update!(verification_status: "verified", verified_at: Time.current)
    assert_not @user.reload.marketplace_verified?
    assert_equal :pending, Directory::Verification.activate_if_ready!(user: @user).status
  end

  test "approval requires email confirmation a fresh directory check identity attestation and a note" do
    assert request_review.success?
    assert_not review.success?
    @user.update!(email_verified_at: Time.current)
    assert_not review.success?, "pre-request directory evidence must not be sufficient"
    attach_directory
    assert_not review(identity_checked: false).success?
    assert_not review(note: " ").success?
    assert_not review(note: "x" * 2_001).success?
    assert_nil @profile.reload.email_reviewed_at
  end

  test "approval activates the member without claiming access to the old directory mailbox" do
    prepare_review
    result = review
    assert result.success?, result.errors.join(", ")
    assert_equal "approved", @profile.reload.email_review_status
    assert_equal @admin.id, @profile.email_reviewed_by_user_id
    assert_nil @profile.directory_email_verified_at
    assert @profile.email_review_approved?
    assert @user.reload.marketplace_verified?
    assert_equal 1, AuditEvent.where(auditable: @profile, action: "email_access.approved").count
    assert_not review.success?
    assert_equal 1, AuditEvent.where(auditable: @profile, action: "email_access.approved").count
  end

  test "stale review forms and member actors cannot approve" do
    prepare_review
    old_digest = @profile.email_review_current_identity_digest
    @profile.update!(directory_email: "new-listed@example.test")
    assert_not review(identity_digest: old_digest).success?
    assert_not review(actor: @user).success?
    assert_not review(actor: nil).success?
    @admin.update!(suspended_at: Time.current)
    assert_not review.success?
    assert @profile.reload.email_review_pending?
  end

  test "an approved manual claim prevents another account claiming the same directory profile" do
    prepare_review
    other = create_marketplace_account(prefix: "claimed-directory")
    other.profile.update!(directory_profile_id: @directory_id, email_review_status: "approved",
      email_review_email_address: other.user.email_address)
    result = review
    assert_not result.success?
    assert_includes result.errors, I18n.t("email_access.errors.claimed")
    assert @profile.reload.email_review_pending?
  end

  test "the database also enforces manual and ordinary claim uniqueness" do
    prepare_review
    assert review.success?
    other = create_marketplace_account(prefix: "db-claim")
    assert_raises ActiveRecord::RecordNotUnique do
      other.profile.update_columns(directory_profile_id: @directory_id, directory_email_verified_at: Time.current)
    end
  end

  test "the automatic lookup treats a manually approved profile as already claimed" do
    prepare_review
    assert review.success?
    other = create_marketplace_account(prefix: "automatic-claim", verified: false)
    evidence = directory_evidence(name: other.user.full_name)
    result = Directory::Verification.request!(user: other.user, lookup: lookup_returning(evidence))
    assert_equal :already_claimed, result.status
    assert_nil other.profile.reload.directory_profile_id
  end

  test "same identity directory refresh preserves approval and changed source closes access" do
    prepare_review
    assert review.success?
    result = Directory::Verification.request!(user: @user, lookup: lookup_returning(directory_evidence))
    assert result.success?
    assert @profile.reload.email_review_approved?
    assert @user.reload.marketplace_verified?
    changed = directory_evidence(email: "changed-directory@example.test")
    Directory::Verification.request!(user: @user, lookup: lookup_returning(changed))
    assert @profile.reload.email_review_pending?
    assert_not @user.reload.marketplace_verified?
    assert_nil @profile.email_review_identity_digest
  end

  test "ordinary email changes clear a manual decision" do
    prepare_review
    assert review.success?
    result = Accounts::ChangeEmail.call(user: @user, current_session: @session,
      password: "password1234", email_address: "another-working@example.test")
    assert result.success?
    assert_nil @profile.reload.email_review_status
    assert_nil @profile.email_review_note
    assert_nil @profile.email_reviewed_by_user_id
    assert_not @user.reload.marketplace_verified?
  end

  test "normal automatic verification remains available without a fallback request" do
    @user.update!(email_verified_at: Time.current)
    result = Directory::Verification.activate_if_ready!(user: @user)
    assert_equal :activated, result.status
    assert @user.reload.marketplace_verified?
    assert @profile.reload.directory_email_verified?
  end

  private

  def request_review(**options)
    Accounts::RequestEmailAccess.call(**{ user: @user, current_session: @session,
      password: "password1234", email_address: @working_email }.merge(options))
  end

  def review(**options)
    Accounts::ReviewEmailAccess.call(**{ user: @user, actor: @admin, decision: "approve",
      note: "Identity checked using the independently published firm telephone number.", identity_checked: true,
      identity_digest: @profile.reload.email_review_current_identity_digest }.merge(options))
  end

  def prepare_review
    assert request_review.success?
    @user.update!(email_verified_at: Time.current)
    attach_directory
  end

  def attach_directory
    @profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{@directory_id}",
      directory_profile_id: @directory_id, directory_name: @user.full_name,
      directory_email: @directory_email, directory_checked_at: Time.current,
      directory_identity_digest: "synthetic-directory-evidence")
  end

  def directory_evidence(name: @user.full_name, email: @directory_email)
    Directory::AdvocaatBeProfileLookup::Result.new(status: :ok, profile_id: @directory_id,
      source_url: @profile.directory_profile_url, name:, email:, checked_at: Time.current)
  end

  def lookup_returning(evidence)
    Class.new.tap { |type| type.define_singleton_method(:call) { |**| evidence } }
  end
end
