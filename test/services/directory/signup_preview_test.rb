require "test_helper"

class DirectorySignupPreviewTest < ActiveSupport::TestCase
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111"

  setup do
    @user = User.new(first_name: "Jane", last_name: "van den Berg", email_address: "working@example.test")
    @profile = @user.build_lawyer_profile(directory_profile_url: PROFILE_URL, spoken_languages: [ "DE" ])
    @result = Directory::SignupProfile::Result.new(status: :ok, profile_url: PROFILE_URL, name: "Jane van den Berg",
      first_name: "Jane", last_name: "van den Berg", email_address: "listed@example.test",
      profile_attributes: { spoken_languages: %w[NL FR], practice_areas: [ "Familierecht" ] })
    @token = Directory::SignupPreview.issue(@result)
  end

  test "imports only signed preferences without confirming the email or directory identity" do
    assert Directory::SignupPreview.apply(@profile, user: @user, token: @token)
    assert_equal %w[NL FR], @profile.spoken_languages
    assert_equal [ "Familierecht" ], @profile.practice_areas
    assert_equal "working@example.test", @user.email_address
    assert_nil @user.email_verified_at
    assert_nil @profile.directory_profile_id
    assert_nil @profile.directory_email
    assert_nil @profile.directory_email_verified_at
    assert_nil @profile.verified_at
  end

  test "manual registration without a preview preserves default profile values" do
    assert Directory::SignupPreview.apply(@profile, user: @user, token: nil)
    assert_equal [ "DE" ], @profile.spoken_languages
  end

  test "forged expired wrong-purpose and malformed previews are rejected" do
    assert_not Directory::SignupPreview.apply(@profile, user: @user, token: @token + "tampered")
    travel 21.minutes do
      assert_not Directory::SignupPreview.apply(@profile, user: @user, token: @token)
    end
    wrong_purpose = verifier.generate(payload, purpose: "another-purpose", expires_in: 20.minutes)
    assert_not Directory::SignupPreview.apply(@profile, user: @user, token: wrong_purpose)
    assert_not Directory::SignupPreview.apply(@profile, user: @user, token: "x" * 16_385)
    assert_equal [ "DE" ], @profile.spoken_languages
  end

  test "the preview is bound to the canonical URL and complete directory name" do
    @profile.directory_profile_url = PROFILE_URL.sub("11111111", "22222222")
    assert_not Directory::SignupPreview.apply(@profile, user: @user, token: @token)
    @profile.directory_profile_url = PROFILE_URL
    @user.first_name = "Different"
    assert_not Directory::SignupPreview.apply(@profile, user: @user, token: @token)
    @user.first_name = "Jane"
    @user.last_name = "van-den Berg"
    assert Directory::SignupPreview.apply(@profile, user: @user, token: @token)
  end

  test "signed attributes outside the allowlist or unbounded lists are rejected" do
    [ { "verification_status" => "verified" }, { "spoken_languages" => "NL" },
      { "practice_areas" => [ "x" * 101 ] }, { "practice_areas" => Array.new(21, "Civil") } ].each do |attributes|
      token = verifier.generate(payload.merge("profile_attributes" => attributes), purpose: Directory::SignupPreview::PURPOSE, expires_in: 20.minutes)
      assert_not Directory::SignupPreview.apply(@profile, user: @user, token:)
    end
    assert_equal [ "DE" ], @profile.spoken_languages
    assert_nil @profile.verified_at
  end

  private

  def payload
    { "profile_url" => PROFILE_URL, "name" => "Jane van den Berg", "profile_attributes" => {} }
  end

  def verifier
    Rails.application.message_verifier(Directory::SignupPreview::PURPOSE)
  end
end
