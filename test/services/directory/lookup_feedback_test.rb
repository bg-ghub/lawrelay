require "test_helper"

class DirectoryLookupFeedbackTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(first_name: "Jane", last_name: "Lawyer", email_address: "login@example.test", email_verified_at: Time.current)
    @firm = Firm.create!(name: "Feedback Legal", verification_status: "pending")
    @user.memberships.create!(firm: @firm, role: "owner")
    @profile = @user.create_lawyer_profile!(bar_association: "OVB", bar_number: "FEEDBACK-#{SecureRandom.hex(5)}",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
  end

  test "known failures persist only a safe code and identity digest without changing proof" do
    proof_fields = %w[directory_profile_id directory_name directory_email directory_checked_at directory_email_verified_at directory_identity_digest verified_at verification_status]
    original_proof = @profile.attributes.slice(*proof_fields)

    LawyerProfile::DIRECTORY_LOOKUP_FAILURES.each do |code|
      result = Directory::Verification.request!(user: @user, lookup: lookup(code.to_sym))

      assert_equal code.to_sym, result.status
      assert_equal code, @profile.reload.directory_lookup_failure
      assert_equal original_proof, @profile.attributes.slice(*proof_fields)
      event = AuditEvent.where(auditable: @profile, action: "verification.directory_lookup_failed").last
      assert_equal %w[identity_digest status], event.metadata.keys.sort
      assert_equal code, event.metadata.fetch("status")
      assert_match(/\A[0-9a-f]{64}\z/, event.metadata.fetch("identity_digest"))
      refute_includes event.metadata.to_json, "private-directory@example.test"
      refute_includes event.metadata.to_json, "Unconfirmed Directory Name"
    end
  end

  test "unknown provider statuses do not become persisted feedback" do
    assert_no_difference "AuditEvent.count" do
      Directory::Verification.request!(user: @user, lookup: lookup(:unknown_failure))
    end
    assert_nil @profile.reload.directory_lookup_failure
  end

  test "a failure for an outdated name or profile link does not affect the current identity" do
    [ :name, :url ].each do |change|
      user = @user
      profile = @profile
      result = failure(:name_mismatch)
      changing_lookup = Object.new
      changing_lookup.define_singleton_method(:call) do |**|
        if change == :name
          user.update!(first_name: "Changed")
        else
          profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111")
        end
        result
      end

      assert_no_difference "AuditEvent.count" do
        Directory::Verification.request!(user: @user, lookup: changing_lookup)
      end
      assert_nil @profile.reload.directory_lookup_failure
      @user.update!(first_name: "Jane")
      @profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    end
  end

  test "later identity changes hide an old failure" do
    Directory::Verification.request!(user: @user, lookup: lookup(:name_mismatch))
    @user.update!(first_name: "Changed")
    assert_nil @profile.reload.directory_lookup_failure

    @user.update!(first_name: "Jane")
    @profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111")
    assert_nil @profile.reload.directory_lookup_failure
  end

  test "successful matching clears earlier failure feedback" do
    Directory::Verification.request!(user: @user, lookup: lookup(:unavailable))
    evidence = Directory::AdvocaatBeProfileLookup::Result.new(status: :ok,
      profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a", source_url: @profile.directory_profile_url,
      name: @user.full_name, email: "professional@example.test", checked_at: Time.current)

    assert_equal :matched, Directory::Verification.request!(user: @user, lookup: provider(evidence)).status
    assert @profile.reload.directory_matched?
    assert_nil @profile.directory_lookup_failure
  end

  test "protected accounts and profiles do not accumulate lookup failure events" do
    @user.update!(suspended_at: Time.current, suspension_reason: "Test suspension")
    assert_no_difference "AuditEvent.count" do
      assert_equal :protected, Directory::Verification.request!(user: @user, lookup: lookup(:unavailable)).status
    end
    @user.update!(suspended_at: nil, suspension_reason: nil)

    %w[rejected suspended verified].each do |status|
      @profile.update!(verification_status: status)
      assert_no_difference "AuditEvent.count" do
        Directory::Verification.request!(user: @user, lookup: lookup(:unavailable))
      end
      assert_nil @profile.reload.directory_lookup_failure
    end
    @profile.update!(verification_status: "pending")
    @firm.update!(verification_status: "rejected")
    assert_no_difference "AuditEvent.count" do
      Directory::Verification.request!(user: @user, lookup: lookup(:unavailable))
    end
  end

  test "unknown or stale audit metadata is never a presentation key" do
    AuditEvent.create!(auditable: @profile, action: "verification.directory_lookup_failed",
      metadata: { status: "<script>untrusted</script>", identity_digest: @profile.directory_lookup_identity_digest })
    assert_nil @profile.directory_lookup_failure
    AuditEvent.create!(auditable: @profile, action: "verification.directory_lookup_failed",
      metadata: { status: "name_mismatch", identity_digest: "stale" })
    assert_nil @profile.directory_lookup_failure
  end

  private

  def lookup(status)
    provider(failure(status))
  end

  def failure(status)
    Directory::AdvocaatBeProfileLookup::Result.new(status:, profile_id: nil, source_url: nil,
      name: "Unconfirmed Directory Name", email: "private-directory@example.test", checked_at: nil)
  end

  def provider(result)
    Struct.new(:result) { def call(**) = result }.new(result)
  end
end
