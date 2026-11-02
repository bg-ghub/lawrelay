require "test_helper"
require_relative "../support/marketplace_test_factory"

class MarketplaceEligibilityTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  test "awarding rejects a candidate whose account or professional eligibility changed" do
    owner = create_marketplace_account(prefix: "eligibility-owner")
    competing = create_marketplace_account(prefix: "eligibility-competing")
    changes = [
      ->(account) { account.user.update!(suspended_at: Time.current) },
      ->(account) { account.user.update!(erased_at: Time.current) },
      ->(account) { account.user.update!(system_role: "admin") },
      ->(account) { account.user.update!(email_verified_at: nil) },
      ->(account) { account.profile.update!(verification_status: "pending") },
      ->(account) { account.profile.update!(verification_status: "rejected") },
      ->(account) { account.profile.update!(verification_status: "suspended") },
      ->(account) { account.profile.update!(email_review_status: "pending") },
      ->(account) { account.profile.update!(email_review_status: "rejected") },
      ->(account) { account.profile.update!(email_review_status: "approved", email_review_identity_digest: nil) },
      ->(account) { account.firm.update!(verification_status: "pending") },
      ->(account) { account.firm.update!(verification_status: "rejected") },
      ->(account) { account.firm.update!(verification_status: "suspended") },
      ->(account) { account.profile.destroy! },
      ->(account) { account.user.memberships.destroy_all }
    ]

    changes.each_with_index do |change, index|
      candidate = create_marketplace_account(prefix: "eligibility-candidate-#{index}")
      assignment = create_assignment_for(owner)
      proposal = create_proposal_for(assignment, candidate)
      other_proposal = create_proposal_for(assignment, competing)
      change.call(candidate)
      sign_in_as(owner.user)
      assert_award_refused(assignment, proposal, other_proposal)
    end
  end

  test "a legacy proposal without a registered candidate cannot be awarded" do
    owner = create_marketplace_account(prefix: "legacy-award-owner")
    candidate = create_marketplace_account(prefix: "legacy-award-candidate")
    competing = create_marketplace_account(prefix: "legacy-award-competing")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    other_proposal = create_proposal_for(assignment, competing)
    proposal.update!(user: nil)
    sign_in_as(owner.user)

    assert_award_refused(assignment, proposal, other_proposal)
  end

  test "awarding rechecks eligibility rather than trusting a previously loaded candidate" do
    owner = create_marketplace_account(prefix: "cached-owner")
    candidate = create_marketplace_account(prefix: "cached-candidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    assert proposal.user.marketplace_verified?
    LawyerProfile.find(candidate.profile.id).update!(verification_status: "rejected")

    assert_no_difference [ "Notification.count", "AuditEvent.count" ] do
      assert_raises(Proposal::InvalidTransition) { proposal.award!(actor: owner.user) }
    end
    assert_equal "pending", proposal.reload.status
    assert_equal "open", assignment.reload.status
    assert_not proposal.respond_to?(:accept!)
  end

  test "ordinary administrator rejection prevents awarding a previously submitted proposal" do
    owner = create_marketplace_account(prefix: "rejection-owner")
    candidate = create_marketplace_account(prefix: "rejection-candidate")
    competing = create_marketplace_account(prefix: "rejection-competing")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    other_proposal = create_proposal_for(assignment, competing)
    sign_in_as(administrator, admin_mfa: true)

    patch admin_verification_path(candidate.user, locale: :en), params: {
      decision: "reject", verification: { note: "Professional eligibility withdrawn after review." }
    }
    assert_redirected_to admin_verifications_path(locale: :en)
    assert_equal "rejected", candidate.profile.reload.verification_status
    assert_equal "rejected", candidate.firm.reload.verification_status

    sign_in_as(owner.user)
    assert_award_refused(assignment, proposal, other_proposal)
  end

  test "an attached proposal never falls back to its old contact snapshot while verification is pending" do
    candidate = create_marketplace_account(prefix: "contact-snapshot")
    assignment = create_assignment_for(create_marketplace_account(prefix: "snapshot-owner"))
    proposal = create_proposal_for(assignment, candidate)
    candidate.user.update!(email_verified_at: nil)

    assert proposal.email.present?
    assert_nil proposal.reload.contact_email
  end

  test "changed contact emails stay hidden in both directions until verification is restored" do
    owner = create_marketplace_account(prefix: "contact-owner")
    candidate = create_marketplace_account(prefix: "contact-candidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(owner.user)
    patch accept_assignment_proposal_path(assignment, proposal, locale: :en)
    assert_equal "accepted", proposal.reload.status

    change_email(candidate, "unconfirmed-candidate@example.test")
    sign_in_as(owner.user)
    get assignment_path(assignment, locale: :en)
    assert_response :success
    assert_select ".contact-card", count: 0
    assert_not_includes response.body, "unconfirmed-candidate@example.test"
    restore_verification(candidate)
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:unconfirmed-candidate@example.test']", count: 1

    change_email(owner, "unconfirmed-owner@example.test")
    sign_in_as(candidate.user)
    get assignment_path(assignment, locale: :en)
    assert_response :success
    assert_select ".contact-card", count: 0
    assert_not_includes response.body, "unconfirmed-owner@example.test"
    restore_verification(owner)
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:unconfirmed-owner@example.test']", count: 1
  end

  test "audited manual activation still allows awarding and contact exchange without inventing email confirmation" do
    owner = manually_activated_account("manual-contact-owner")
    candidate = manually_activated_account("manual-contact-candidate")
    assignment = create_assignment_for(owner)
    proposal = create_proposal_for(assignment, candidate)
    sign_in_as(owner.user)

    patch accept_assignment_proposal_path(assignment, proposal, locale: :en)
    assert_equal "matched", assignment.reload.status
    assert_equal "accepted", proposal.reload.status
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:#{candidate.user.email_address}']", count: 1
    sign_in_as(candidate.user)
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:#{owner.user.email_address}']", count: 1
    assert_nil owner.user.reload.email_verified_at
    assert_nil candidate.user.reload.email_verified_at
  end

  private

  def assert_award_refused(assignment, proposal, other_proposal)
    clear_enqueued_jobs
    assert_no_difference [ "Notification.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        patch accept_assignment_proposal_path(assignment, proposal, locale: :en)
      end
    end
    assert_redirected_to assignment_path(assignment, locale: :en)
    assert_equal "open", assignment.reload.status
    assert_equal "pending", proposal.reload.status
    assert_equal "pending", other_proposal.reload.status
    assert_nil proposal.accepted_at
  end

  def change_email(account, email)
    result = Admin::UserManagement.new(actor: administrator, user: account.user).update!(email_address: email)
    assert result.email_changed
    assert_equal email, account.user.reload.email_address
    assert_not account.user.email_verified?
    assert_not account.user.marketplace_verified?
  end

  def restore_verification(account)
    account.user.reload.update!(email_verified_at: Time.current)
    account.profile.reload.update!(verification_status: "verified", verified_at: Time.current)
  end

  def administrator
    @administrator ||= create_marketplace_account(prefix: "eligibility-admin", system_role: "admin").user.tap do |user|
      secret = user.begin_admin_mfa_setup!
      user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    end
  end

  def manually_activated_account(prefix)
    account = create_marketplace_account(prefix:, verified: false, email_verified: false)
    profile_id = SecureRandom.uuid
    account.profile.update!(directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: account.user.full_name, directory_email: account.user.email_address,
      directory_checked_at: Time.current)
    result = Admin::ManualActivation.call(user: account.user, actor: administrator,
      note: "Synthetic operator reviewed the professional identity.",
      identity_digest: account.profile.email_review_current_identity_digest)
    assert result.success?, result.status.to_s
    account.user.reload
    account.profile.reload
    account
  end
end
