require "test_helper"

class DirectoryVerificationTest < ActiveSupport::TestCase
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

  test "different login and directory emails require both verifications" do
    Directory::Verification.request!(user: @user, lookup: @lookup)
    @profile.reload
    refute @profile.directory_email_verified?
    refute @profile.verified?

    Directory::Verification.confirm!(@profile)
    refute @profile.reload.verified?
    @user.update!(email_verified_at: Time.current)
    assert_equal :activated, Directory::Verification.activate_if_ready!(user: @user).status
    assert @profile.reload.verified?
    assert @firm.reload.verified?
  end

  test "same authoritative email is accepted only after login email verification" do
    @user.update!(email_address: "directory@example.test")
    Directory::Verification.request!(user: @user, lookup: @lookup)
    refute @profile.reload.directory_email_verified?

    @user.update!(email_verified_at: Time.current)
    assert_equal :activated, Directory::Verification.activate_if_ready!(user: @user).status
    assert @profile.reload.directory_email_verified?
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

  test "confirmation token is bound to the stored directory identity" do
    @profile.update!(directory_profile_id: @evidence.profile_id, directory_profile_url: @evidence.source_url, directory_name: @evidence.name,
      directory_email: @evidence.email, directory_checked_at: Time.current, directory_identity_digest: "digest")
    token = Directory::ConfirmationToken.generate(@profile)
    @profile.update!(directory_email: "changed@example.test")

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { Directory::ConfirmationToken.find_profile!(token) }
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
end
