require "test_helper"
require_relative "../../support/marketplace_test_factory"

class PrivacyAccountErasureTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActionMailer::TestHelper
  self.use_transactional_tests = false

  # These cases must exercise real commits for the external ledger protocol.
  # Clear disposable records before Rails reloads its users-only fixtures.
  def before_setup
    clear_disposable_database
    super
  end

  def after_teardown
    super
  ensure
    clear_disposable_database
  end

  setup do
    @member = create_marketplace_account(prefix: "erase-member")
    @other = create_marketplace_account(prefix: "erase-other")
    @user = @member.user
    @admin = User.create!(first_name: "Privacy", last_name: "Operator", email_address: "erase-operator@example.test",
      password: "safe-password-123", system_role: "admin", email_verified_at: Time.current,
      admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    @request = @user.privacy_requests.create!(kind: "deletion", status: "in_review", handled_by_user: @admin,
      details: "Please erase my private name and account")
    @ledger = Struct.new(:entries) do
      def stage!(user, erased_at:)
        entries << { "version" => 1, "user_id" => user.id,
          "user_created_at" => user.created_at.utc.iso8601(6), "erased_at" => erased_at.utc.iso8601(6) }
        "synthetic-operation"
      end
      def commit!(_operation) = true
      def abort!(_operation) = entries.clear
      def reconcile! = true
    end.new([])
  end

  test "reviewed erasure removes profile, authentication and authored personal content without deleting shared work" do
    assignment = create_assignment_for(@member)
    assignment.update_columns(invoice_name: "Private invoice firm", invoice_enterprise_number: "BE0123456789",
      invoice_email: "private-invoice@example.test", invoice_address_line_1: "Private street 1", invoice_postal_code: "9000", invoice_city: "Gent",
      invoice_kbo_details: { "snapshot_date" => "2026-10-15", "fields" => [ "name", "enterprise_number" ] })
    @member.firm.update!(kbo_details: { "snapshot_date" => "2026-10-15", "fields" => [ "name", "enterprise_number" ] })
    assignment.update_columns(status: "completed", starts_at: 1.day.ago, closed_at: Time.current)
    proposal = create_proposal_for(assignment, @other)
    own_proposal_assignment = create_assignment_for(@other)
    own_proposal = create_proposal_for(own_proposal_assignment, @member, message: "Private authored message")
    own_proposal_assignment.update_columns(status: "completed", starts_at: 1.day.ago, closed_at: Time.current)
    @user.sessions.create!
    @user.update!(two_factor_secret_ciphertext: "synthetic-secret", two_factor_recovery_code_digests: [ "synthetic-hash" ])
    profile_id = @member.profile.id
    @member.profile.update_columns(email_review_status: "approved", email_review_email_address: @user.email_address,
      email_review_requested_at: 2.hours.ago, email_reviewed_at: 1.hour.ago, email_reviewed_by_user_id: @admin.id,
      email_review_note: "Private identity review", email_review_identity_digest: "private-review-digest")
    review_event = AuditEvent.create!(auditable: @member.profile, actor_user: @admin, firm: @member.firm,
      action: "email_access.approved", metadata: { note: "Private independent contact evidence" })
    old_email = @user.email_address
    old_password = @user.password_digest
    AuditEvent.create!(auditable: assignment, actor_user: @user, action: "assignment.created", metadata: { name: "Private name" })

    assert_no_enqueued_emails { erase }
    @user.reload
    assert_not @user.active?
    assert @user.erased_at
    assert_not_equal old_email, @user.email_address
    assert_not_equal old_password, @user.password_digest
    assert_nil @user.lawyer_profile
    assert_not LawyerProfile.exists?(profile_id)
    assert_equal({}, review_event.reload.metadata)
    assert_empty @user.sessions
    assert_empty @user.memberships
    assert_empty @user.notifications
    assert_nil @user.two_factor_secret_ciphertext
    assert_empty @user.two_factor_recovery_code_digests
    assert_equal "completed", @request.reload.status
    assert_not_includes @request.details, "private name"
    assert_equal "completed", assignment.reload.status
    assert_not_includes assignment.description, "Synthetic assignment"
    assert_nil assignment.invoice_name
    assert_nil assignment.invoice_enterprise_number
    assert_nil assignment.invoice_email
    assert_nil assignment.invoice_address_line_1
    assert_nil assignment.invoice_postal_code
    assert_nil assignment.invoice_city
    assert_equal({}, assignment.invoice_kbo_details)
    assert_equal({}, @member.firm.reload.kbo_details)
    assert_equal I18n.t("retention.removed_content", locale: @user.locale), own_proposal.reload.message
    assert_nil own_proposal.contact_email
    assert_equal @other.user, proposal.reload.user
    assert @other.user.reload.active?
    assert_equal [ @user.id ], @ledger.entries.pluck("user_id")
    assert_not_includes @ledger.entries.to_json, old_email
    assert_equal({}, AuditEvent.find_by(action: "assignment.created", auditable: assignment).metadata)
    assert AuditEvent.exists?(auditable: @user, action: "privacy.account_erased")
  end

  test "a shared firm's contact data and other memberships remain intact" do
    @other.user.memberships.create!(firm: @member.firm)
    @member.firm.update!(phone: "+32 123456", address_line_1: "Shared office")
    original = @member.firm.attributes
    erase
    assert_equal original, @member.firm.reload.attributes
    assert Membership.exists?(user: @other.user, firm: @member.firm)
  end

  test "ongoing work, recorded holds and another open privacy request prevent erasure" do
    assignment = create_assignment_for(@member)
    assert_raises(Privacy::AccountErasure::ProtectedAccount) { erase }
    assignment.update_columns(status: "completed", starts_at: 1.day.ago, closed_at: Time.current)
    hold = RetentionHold.create!(subject: assignment, actor: @admin, reason: "Dispute test", expires_at: 30.days.from_now)
    assert_raises(Privacy::AccountErasure::ProtectedAccount) { erase }
    hold.destroy!
    other_request = @user.privacy_requests.create!(kind: "restriction", details: "Restrict processing")
    assert_raises(Privacy::AccountErasure::ProtectedAccount) { erase }
    other_request.destroy!
    assert_empty @ledger.entries
    assert @user.reload.active?
  end

  test "unreviewed requests, wrong operators and administrators cannot be erased" do
    @request.update!(status: "pending")
    assert_raises(Privacy::RequestContext::InvalidRequest) { erase }
    @request.update!(status: "in_review")
    assert_raises(Privacy::RequestContext::InvalidRequest) do
      Privacy::AccountErasure.new(request: @request, actor: @other.user, ledger: @ledger).call
    end
    @request.update!(user: @admin)
    assert_raises(Privacy::RequestContext::InvalidRequest) { erase }
    assert_empty @ledger.entries
  end

  test "ledger failure leaves the account and request unchanged" do
    @ledger.define_singleton_method(:stage!) { |*args, **kwargs| raise Privacy::ErasureLedger::UnsafeLedger, "Unavailable" }
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { erase }
    assert @user.reload.active?
    assert @user.lawyer_profile
    assert_equal "in_review", @request.reload.status
  end

  test "a failed database mutation aborts its staged erasure" do
    original = Privacy::AccountErasure.method(:scrub!)
    Privacy::AccountErasure.define_singleton_method(:scrub!) { |*args, **kwargs| raise ActiveRecord::RecordInvalid }
    assert_raises(ActiveRecord::RecordInvalid) { erase }
    assert @user.reload.active?
    assert_empty @ledger.entries
  ensure
    Privacy::AccountErasure.define_singleton_method(:scrub!, original) if original
  end

  test "minimal account and closed work records expire together after two years" do
    assignment = create_assignment_for(@member)
    assignment.update_columns(status: "completed", starts_at: 1.day.ago, closed_at: Time.current)
    erase

    travel_to 2.years.from_now + 2.days do
      2.times { Retention::Cleanup.new(dry_run: false).call }
    end

    assert_not Assignment.exists?(assignment.id)
    assert_not PrivacyRequest.exists?(@request.id)
    assert_not User.exists?(@user.id)
    assert User.exists?(@other.user.id)
    assert User.exists?(@admin.id)
  end

  test "restored accounts are scrubbed before traffic and replay is idempotent" do
    original = @user.attributes
    erase
    @user.update_columns(original.except("id"))
    assignment = create_assignment_for(@member)
    assert_equal 1, Privacy::AccountErasure.reapply!(ledger: @ledger)
    assert_not @user.reload.active?
    assert_equal "cancelled", assignment.reload.status
    assert_equal 0, Privacy::AccountErasure.reapply!(ledger: @ledger)
    assert_raises(Admin::UserManagement::InvalidAction) do
      Admin::UserManagement.new(actor: @admin, user: @user).restore!(reason: "Cannot undo erasure")
    end
  end

  test "a ledger identity mismatch fails closed" do
    @ledger.stage!(@user, erased_at: Time.current)
    @ledger.entries.first["user_created_at"] = 1.day.ago.utc.iso8601(6)
    assert_raises(Privacy::AccountErasure::ProtectedAccount) { Privacy::AccountErasure.reapply!(ledger: @ledger) }
    assert @user.reload.active?
  end

  test "stale forms cannot create new personal records after erasure" do
    own_assignment = create_assignment_for(@member)
    own_assignment.update_columns(status: "completed", starts_at: 1.day.ago, closed_at: Time.current)
    other_assignment = create_assignment_for(@other)
    stale_user = User.find(@user.id)
    assignment = own_assignment.dup
    assignment.assign_attributes(creator_user: stale_user, status: "open", starts_at: 3.days.from_now)
    proposal = other_assignment.proposals.build(user: stale_user, firm: @member.firm, name: stale_user.full_name,
      email: stale_user.email_address, rate_cents: 100, message: "Stale personal message")
    report = Report.new(reporter_user: stale_user, reportable: other_assignment, category: "other", details: "Stale report")
    request = PrivacyRequest.new(user: stale_user, kind: "access_export", details: "Stale request")
    erase

    [ assignment, proposal, report, request ].each { |record| assert_not record.save }
  end

  test "a report cached before old work was removed cannot become an orphan" do
    assignment = create_assignment_for(@other)
    report = Report.new(reporter_user: @user, reportable: assignment, category: "other", details: "Stale form")
    assignment.destroy!

    assert_not report.save
    assert_not Report.exists?(reportable_type: "Assignment", reportable_id: assignment.id)
  end

  private

  def clear_disposable_database
    raise "Test database required" unless Rails.env.test?

    connection = ApplicationRecord.connection
    connection.disable_referential_integrity do
      (connection.tables - %w[schema_migrations ar_internal_metadata]).each do |table|
        connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
      end
    end
    ActiveRecord::FixtureSet.reset_cache
  end

  def erase
    Privacy::AccountErasure.new(request: @request, actor: @admin, ledger: @ledger).call
  end
end
