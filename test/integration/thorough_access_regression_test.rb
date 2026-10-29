require "test_helper"
require_relative "../support/marketplace_test_factory"

class ThoroughAccessRegressionTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "expired directory verification GET returns to sign in without confirming proof" do
    account, token = directory_confirmation

    travel 49.hours do
      get directory_verification_path(token:, locale: :fr)

      assert_redirected_to new_session_path(locale: :fr)
      assert_not account.profile.reload.directory_email_verified?
    end
  end

  test "expired directory verification POST cannot activate an account" do
    account, token = directory_confirmation

    travel 49.hours do
      assert_no_difference "AuditEvent.count" do
        post confirm_directory_verification_path(token:, locale: :de)
      end

      assert_redirected_to new_session_path(locale: :de)
      assert_not account.profile.reload.directory_email_verified?
      assert_not account.profile.verified?
      assert_not account.firm.reload.verified?
    end
  end

  test "suspension invalidates an already issued session before a proposal can be created" do
    owner = create_marketplace_account(prefix: "suspensionowner")
    candidate = create_marketplace_account(prefix: "suspendedcandidate")
    assignment = create_assignment_for(owner)
    sign_in_as(candidate.user)
    session_id = Current.session.id
    candidate.user.update!(suspended_at: Time.current, suspension_reason: "Account review")

    assert_no_difference [ "Proposal.count", "AuditEvent.count" ] do
      post assignment_proposals_path(assignment, locale: :en), params: {
        proposal: { rate_cents: "250", message: "This request must be rejected." }
      }
    end

    assert_redirected_to new_session_path(locale: :en)
    assert_not Session.exists?(session_id)
  end

  test "a pending lawyer cannot submit a report for a visible assignment" do
    owner = create_marketplace_account(prefix: "pendingreportowner")
    pending = create_marketplace_account(prefix: "pendingreporter", verified: false)
    assignment = create_assignment_for(owner)
    sign_in_as(pending.user)

    assert_no_difference [ "Report.count", "AuditEvent.count" ] do
      post assignment_reports_path(assignment, locale: :en), params: {
        report: { category: "misleading", details: "This pending account must not submit a report." }
      }
    end

    assert_redirected_to verification_status_path(locale: :en)
  end

  test "an expired MFA confirmation blocks admin mutations before changing the target" do
    admin = create_marketplace_account(prefix: "stalemfaadmin", system_role: "admin")
    target = create_marketplace_account(prefix: "stalemfatarget")
    secret = admin.user.begin_admin_mfa_setup!
    admin.user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_in_as(admin.user, admin_mfa: true)
    Current.session.update!(admin_mfa_verified_at: 13.hours.ago)

    assert_no_difference "AuditEvent.count" do
      patch suspend_admin_user_path(target.user, locale: :en), params: {
        user_management: { reason: "This unconfirmed request must not take effect." }
      }
    end

    assert_redirected_to admin_mfa_challenge_path(locale: :en)
    assert_predicate target.user.reload, :active?
  end

  test "configured admin cannot restart MFA enrollment through a direct setup POST" do
    admin = create_marketplace_account(prefix: "mfareenrollment", system_role: "admin")
    secret = admin.user.begin_admin_mfa_setup!
    admin.user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    original_ciphertext = admin.user.admin_mfa_secret_ciphertext
    sign_in_as(admin.user)
    session_id = Current.session.id

    assert_no_difference "AuditEvent.count" do
      post admin_mfa_setup_path(locale: :en), params: { mfa_code: "000000" }
    end

    assert_redirected_to admin_mfa_challenge_path(locale: :en)
    assert_nil admin.user.reload.admin_mfa_pending_secret_ciphertext
    assert_equal original_ciphertext, admin.user.admin_mfa_secret_ciphertext
    assert_not Session.find(session_id).admin_mfa_verified?
  end

  test "a member cannot enter user administration by submitting an admin role" do
    member = create_marketplace_account(prefix: "forgedadmin")
    target = create_marketplace_account(prefix: "forgedadmintarget")
    sign_in_as(member.user, admin_mfa: true)

    assert_no_difference "AuditEvent.count" do
      patch admin_user_path(target.user, locale: :en), params: {
        user: { first_name: "Changed", system_role: "admin" },
        system_role: "admin"
      }
    end

    assert_redirected_to root_path(locale: :en)
    assert_equal "Forgedadmintarget", target.user.reload.first_name
    assert_equal "member", member.user.reload.system_role
  end

  test "privacy request ownership and resolution fields cannot be forged" do
    requester = create_marketplace_account(prefix: "privacyforgery")
    other = create_marketplace_account(prefix: "privacyforgeryother")
    sign_in_as(requester.user)

    assert_difference "PrivacyRequest.count", 1 do
      post privacy_requests_path(locale: :en), params: {
        privacy_request: {
          kind: "access_export", details: "Please provide my account data.",
          user_id: other.user.id, handled_by_user_id: other.user.id,
          status: "completed", resolution_note: "Forged resolution", resolved_at: Time.current
        }
      }
    end

    assert_redirected_to privacy_requests_path(locale: :en)
    request_record = PrivacyRequest.order(:id).last
    assert_equal requester.user.id, request_record.user_id
    assert_equal "pending", request_record.status
    assert_nil request_record.handled_by_user_id
    assert_nil request_record.resolution_note
    assert_nil request_record.resolved_at
  end

  test "an unrelated lawyer cannot report a closed assignment by guessing its id" do
    owner = create_marketplace_account(prefix: "closedreportowner")
    outsider = create_marketplace_account(prefix: "closedreportoutsider")
    assignment = create_assignment_for(owner, status: "completed")
    sign_in_as(outsider.user)

    get new_assignment_report_path(assignment, locale: :en)
    assert_redirected_to assignments_path(locale: :en)

    assert_no_difference [ "Report.count", "AuditEvent.count" ] do
      post assignment_reports_path(assignment, locale: :en), params: {
        report: { category: "other", details: "This private assignment must not be addressable." }
      }
    end
    assert_redirected_to assignments_path(locale: :en)
  end

  test "proposal mutation resolves the proposal through the assignment in the URL" do
    owner = create_marketplace_account(prefix: "nestedowner")
    other_owner = create_marketplace_account(prefix: "nestedotherowner")
    candidate = create_marketplace_account(prefix: "nestedcandidate")
    own_assignment = create_assignment_for(owner)
    other_assignment = create_assignment_for(other_owner)
    other_proposal = create_proposal_for(other_assignment, candidate)
    sign_in_as(owner.user)

    assert_no_difference "AuditEvent.count" do
      patch accept_assignment_proposal_path(own_assignment, other_proposal, locale: :en)
    end

    assert_response :not_found
    assert_equal "open", own_assignment.reload.status
    assert_equal "open", other_assignment.reload.status
    assert_equal "pending", other_proposal.reload.status
  end

  private

  def directory_confirmation
    account = create_marketplace_account(prefix: "expiringdirectory", verified: false)
    profile_id = SecureRandom.uuid
    account.profile.update!(
      directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: account.user.full_name,
      directory_email: "professional-#{SecureRandom.hex(4)}@example.test",
      directory_checked_at: Time.current,
      directory_identity_digest: SecureRandom.hex(32)
    )
    [ account, Directory::ConfirmationToken.generate(account.profile) ]
  end
end
