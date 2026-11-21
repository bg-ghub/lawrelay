require "test_helper"

class DirectoryVerificationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    @user = users(:one)
    @user.update!(first_name: "Jane", last_name: "Lawyer", email_address: "login@example.test", email_verified_at: nil)
    @firm = Firm.create!(name: "Jane Lawyer", verification_status: "pending")
    Membership.create!(user: @user, firm: @firm, role: "owner")
    @profile = LawyerProfile.create!(user: @user, bar_association: "OVB", bar_number: "TEST-#{SecureRandom.hex(5)}")
    @evidence = Directory::AdvocaatBeProfileLookup::Result.new(
      status: :ok, profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      source_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      name: "Jane Lawyer", email: "directory@example.test", checked_at: Time.current
    )
    @lookup = Struct.new(:result) { def call(**) = result }.new(@evidence)
  end

  test "different login and directory emails require manual approval even after both inboxes are confirmed" do
    assert_no_enqueued_jobs only: Directory::ConfirmationJob do
      Directory::Verification.request!(user: @user, lookup: @lookup)
    end
    @profile.reload
    refute @profile.directory_email_verified?
    refute @profile.verified?

    Directory::Verification.confirm!(@profile)
    refute @profile.reload.verified?
    @user.update!(email_verified_at: Time.current)
    assert_equal :pending, Directory::Verification.activate_if_ready!(user: @user).status
    assert_not @profile.reload.verified?
    assert_not @firm.reload.verified?
    assert @user.reload.directory_email_review_required?
    assert_not @user.marketplace_verified?
  end

  test "same authoritative email is accepted only after login email verification" do
    @user.update!(email_address: "directory@example.test")
    Directory::Verification.request!(user: @user, lookup: @lookup)
    refute @profile.reload.directory_email_verified?

    @user.update!(email_verified_at: Time.current)
    assert_equal :activated, Directory::Verification.activate_if_ready!(user: @user).status
    assert @profile.reload.directory_email_verified?
  end

  test "a move between signup preview and onboarding must still match the email in the preview" do
    @profile.update!(directory_profile_url: @evidence.source_url, directory_name: @evidence.name, directory_email: @evidence.email)
    destination = SecureRandom.uuid
    @lookup.result = @evidence.with(original_profile_id: @evidence.profile_id, profile_id: destination,
      source_url: @evidence.source_url.sub(@evidence.profile_id, destination), email: "changed@example.test")
    assert_no_difference "DirectoryProfileLink.count" do
      assert_equal :identity_mismatch, Directory::Verification.request!(user: @user, lookup: @lookup).status
    end
    assert_equal @evidence.email, @profile.reload.directory_email
    assert_nil @profile.directory_checked_at
    refute @profile.verified?
  end

  test "an unverified claimant cannot block the rightful verified claimant" do
    Directory::Verification.request!(user: @user, lookup: @lookup)
    second = users(:two)
    second.update!(first_name: "Jane", last_name: "Lawyer")
    second_profile = LawyerProfile.create!(user: second, bar_association: "OVB", bar_number: "TEST-#{SecureRandom.hex(5)}")

    result = Directory::Verification.request!(user: second, lookup: @lookup)
    assert_equal :matched, result.status
    assert_equal :confirmed, Directory::Verification.confirm!(second_profile.reload).status
    assert_equal :already_claimed, Directory::Verification.confirm!(@profile.reload).status
  end

  test "suspended profiles remain protected" do
    @profile.update!(verification_status: "suspended")
    @user.update!(email_verified_at: Time.current)
    @profile.update!(directory_profile_id: @evidence.profile_id, directory_profile_url: @evidence.source_url, directory_name: @evidence.name,
      directory_email: @user.email_address, directory_checked_at: Time.current, directory_email_verified_at: Time.current, directory_identity_digest: "digest")

    assert_equal :protected, Directory::Verification.activate_if_ready!(user: @user).status
    assert_equal "suspended", @profile.reload.verification_status
  end

  test "account suspension prevents directory requests and confirmations without changing the firm" do
    @user.update!(email_verified_at: Time.current)
    Directory::Verification.request!(user: @user, lookup: @lookup)
    token = Directory::ConfirmationToken.generate(@profile.reload)
    @user.update!(suspended_at: Time.current, suspension_reason: "Account review")
    failing_lookup = Object.new
    def failing_lookup.call(**) = raise("Suspended accounts must not fetch the directory")

    assert_equal :protected, Directory::Verification.request!(user: @user.reload, lookup: failing_lookup).status
    assert_equal :protected, Directory::Verification.confirm!(@profile.reload).status
    assert_equal :protected, Directory::Verification.activate_if_ready!(user: @user).status
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(token) }
    assert_not @profile.reload.directory_email_verified?
    assert_equal "pending", @profile.verification_status
    assert_equal "pending", @firm.reload.verification_status
  end

  test "confirmation token is bound to the stored directory identity" do
    @profile.update!(directory_profile_id: @evidence.profile_id, directory_profile_url: @evidence.source_url, directory_name: @evidence.name,
      directory_email: @evidence.email, directory_checked_at: Time.current, directory_identity_digest: "digest")
    token = Directory::ConfirmationToken.generate(@profile)
    @profile.update!(directory_email: "changed@example.test")

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(token) }
  end

  test "an authenticated move of a matched listing preserves the existing confirmation and email evidence" do
    Directory::Verification.request!(user: @user, lookup: @lookup)
    token = Directory::ConfirmationToken.generate(@profile.reload)
    identity = @profile.attributes.slice("directory_profile_id", "directory_profile_url", "directory_identity_digest",
      "directory_email", "directory_name", "directory_email_verified_at", "verification_status")
    destination = SecureRandom.uuid
    moved = @evidence.with(profile_id: destination, original_profile_id: @evidence.profile_id,
      source_url: @evidence.source_url.sub(@evidence.profile_id, destination))
    lookup = Struct.new(:evidence) { def call(**) = evidence }.new(moved)

    assert_equal :matched, Directory::Verification.request!(user: @user, lookup:).status
    assert_equal identity, @profile.reload.attributes.slice(*identity.keys)
    assert_equal @profile, Directory::ConfirmationToken.find_profile!(token)
    assert_equal [ @evidence.profile_id, destination ].sort, DirectoryProfileLink.where(lawyer_profile: @profile).pluck(:directory_profile_id).sort
    lookup.evidence = moved.with(email: "different@example.test", profile_id: SecureRandom.uuid)
    assert_equal :identity_mismatch, Directory::Verification.request!(user: @user, lookup:).status
    assert_equal 2, DirectoryProfileLink.where(lawyer_profile: @profile).count
    direct = moved.with(original_profile_id: destination)
    lookup.evidence = direct
    assert_equal :matched, Directory::Verification.request!(user: @user, directory_profile_url: direct.source_url, lookup:).status
    [ direct.with(email: "different@example.test"), direct.with(name: "Someone Else") ].each do |different|
      lookup.evidence = different
      assert_equal :identity_mismatch, Directory::Verification.request!(user: @user, directory_profile_url: direct.source_url, lookup:).status
      assert_equal identity, @profile.reload.attributes.slice(*identity.keys)
    end
  end

  test "a name change makes an old confirmation token and activation unusable" do
    @profile.update!(directory_profile_id: @evidence.profile_id, directory_profile_url: @evidence.source_url, directory_name: @evidence.name,
      directory_email: @evidence.email, directory_checked_at: Time.current, directory_identity_digest: "digest")
    token = Directory::ConfirmationToken.generate(@profile)
    @user.update!(first_name: "Changed", email_verified_at: Time.current)

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(token) }
    assert_equal :pending, Directory::Verification.activate_if_ready!(user: @user).status
    refute @profile.reload.verified?
  end

  test "new directory confirmation tokens remain valid for seventy two hours" do
    prepare_confirmation_identity
    token = Directory::ConfirmationToken.generate(@profile)

    travel 72.hours - 1.second do
      assert_equal @profile, Directory::ConfirmationToken.find_profile!(token)
    end
    travel 72.hours + 1.second do
      assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(token) }
    end
  end

  test "previous directory tokens retain their embedded forty eight hour expiry" do
    prepare_confirmation_identity
    payload = {
      "profile_id" => @profile.id, "user_id" => @user.id, "directory_profile_id" => @profile.directory_profile_id,
      "identity_digest" => @profile.directory_identity_digest, "directory_email" => @profile.directory_email,
      "directory_name" => @profile.directory_name, "directory_profile_url" => @profile.directory_profile_url,
      "login_email" => @user.email_address, "full_name" => @user.full_name
    }
    legacy_token = Directory::ConfirmationToken.encryptor.encrypt_and_sign(payload, expires_in: 48.hours)

    travel 48.hours - 1.second do
      assert_equal @profile, Directory::ConfirmationToken.find_profile!(legacy_token)
    end
    travel 48.hours + 1.second do
      assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(legacy_token) }
    end
  end

  private

  def prepare_confirmation_identity
    @profile.update!(directory_profile_id: @evidence.profile_id, directory_profile_url: @evidence.source_url, directory_name: @evidence.name,
      directory_email: @evidence.email, directory_checked_at: Time.current, directory_identity_digest: "digest")
  end
end
