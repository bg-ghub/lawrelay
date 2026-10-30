require "test_helper"

class GeoChallengeTest < ActionDispatch::IntegrationTest
  setup do
    @original_enabled = GeoCountry.method(:challenge_enabled?)
    @original_country = GeoCountry.method(:country_for)
    GeoCountry.define_singleton_method(:challenge_enabled?) { true }
  end

  teardown do
    GeoCountry.define_singleton_method(:challenge_enabled?, @original_enabled)
    GeoCountry.define_singleton_method(:country_for, @original_country)
  end

  test "Belgian visitors can view public pages without a challenge" do
    GeoCountry.define_singleton_method(:country_for) { |_| "BE" }
    get root_path(locale: :en)
    assert_response :success
  end

  test "non Belgian visitors are redirected and client supplied geo headers do not bypass it" do
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
    get privacy_path(locale: :en), headers: { "X-Geo-Country" => "BE" }
    assert_redirected_to geo_challenge_path(locale: :en)
  end

  test "signing in bypasses the public visitor challenge" do
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
    user = User.create!(email_address: "geo@example.test", password: "password1234", first_name: "Geo", last_name: "Lawyer")
    sign_in_as(user)
    get root_path(locale: :en)
    assert_response :success
  end

  test "login remains reachable from outside Belgium" do
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
    get new_session_path(locale: :en)
    assert_response :success
  end

  test "a signed verification cookie bypasses a repeat challenge" do
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
    cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
    cookie_jar.signed[:geo_verified] = { value: "verified", expires: 1.hour.from_now }
    cookies["geo_verified"] = cookie_jar[:geo_verified]

    get root_path(locale: :en)
    assert_response :success
  end

  test "a valid proof restores the local public path and cannot be replayed" do
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
    get root_path(locale: :en)
    assert_redirected_to geo_challenge_path(locale: :en)

    get altcha_challenge_path(locale: :en, format: :json)
    challenge = JSON.parse(response.body)
    solution = (0..challenge.fetch("maxnumber")).find do |number|
      OpenSSL::Digest::SHA256.hexdigest("#{challenge.fetch('salt')}#{number}") == challenge.fetch("challenge")
    end
    assert solution
    payload = Base64.strict_encode64(challenge.merge("number" => solution).to_json)

    post geo_challenge_path(locale: :en), params: { altcha: payload }
    assert_redirected_to root_path(locale: :en)
    get root_path(locale: :en)
    assert_response :success

    post geo_challenge_path(locale: :en), params: { altcha: payload }
    assert_response :unprocessable_content
  end

  test "the challenge page alone permits its Blob worker" do
    get geo_challenge_path(locale: :en)

    assert_response :success
    assert_includes response.headers.fetch("content-security-policy"), "worker-src 'self' blob:"
  end
end
