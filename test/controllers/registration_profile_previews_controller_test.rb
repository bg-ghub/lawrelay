require "test_helper"

class RegistrationProfilePreviewsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111"

  setup do
    @original_call = Directory::SignupProfile.method(:call)
    @result = Directory::SignupProfile::Result.new(status: :ok, profile_url: PROFILE_URL, name: "Jane van den Berg",
      first_name: "Jane", last_name: "van den Berg", email_address: "listed@example.test",
      profile_attributes: { spoken_languages: %w[NL FR], practice_areas: [ "Familierecht" ] })
    result = @result
    calls = @calls = []
    Directory::SignupProfile.define_singleton_method(:call) do |**arguments|
      calls << arguments
      result
    end
  end

  teardown do
    Directory::SignupProfile.define_singleton_method(:call, @original_call)
  end

  test "an anonymous preview returns allowlisted suggestions without creating records or sending email" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        post registration_profile_path(locale: :en), params: { registration: { directory_profile_url: PROFILE_URL } }, as: :json
      end
    end
    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal "Jane van den Berg", body["name"]
    assert_equal "listed@example.test", body["email_address"]
    assert body["token"].present?
    assert_equal [ { profile_url: PROFILE_URL } ], @calls
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal %w[email_address first_name last_name name profile_attributes profile_url status token], body.keys.sort
  end

  test "HTML preview prefills missing identity without echoing passwords or forged company details" do
    post registration_profile_path(locale: :en), params: { registration: {
      directory_profile_url: PROFILE_URL, password: "do-not-echo-this-password", password_confirmation: "do-not-echo-this-password",
      firm_name: "My invoice company", enterprise_number: "1234567894", address_line_1: "My invoice street",
      email_address: "working@example.test"
    } }
    assert_response :success
    assert_select "input[name='registration[first_name]'][value='Jane']"
    assert_select "input[name='registration[last_name]'][value='van den Berg']"
    assert_select "input[name='registration[email_address]']", count: 0
    assert_select "[data-registration-profile-target='summaryEmail']", text: "listed@example.test"
    assert_includes response.body, I18n.t("signup_profile.confirm_email", locale: :en)
    assert_not_includes response.body, "working@example.test"
    assert_select "input[name='registration[firm_name]'], input[name='registration[address_line_1]']", count: 0
    assert_not_includes response.body, "My invoice company"
    assert_not_includes response.body, "My invoice street"
    assert_not_includes response.body, "do-not-echo-this-password"
    assert_select "input[name='registration[password]'][value]", count: 0
  end

  test "an imported profile still creates a pending account and minimal internal workspace" do
    assert_enqueued_jobs 2 do
      post registration_path(locale: :en), params: { registration: registration_attributes }
    end
    assert_redirected_to verification_status_path(locale: :en)
    user = User.find_by!(email_address: "listed@example.test")
    assert_nil user.email_verified_at
    assert_equal "pending", user.lawyer_profile.verification_status
    assert_nil user.lawyer_profile.directory_profile_id
    assert_nil user.lawyer_profile.directory_email
    assert_nil user.lawyer_profile.directory_email_verified_at
    assert_equal %w[NL FR], user.lawyer_profile.spoken_languages
    assert_equal [ "Familierecht" ], user.lawyer_profile.practice_areas
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, user.primary_firm.name
    assert_nil user.primary_firm.enterprise_number
    assert_nil user.primary_firm.billing_email
    assert_nil user.primary_firm.address_line_1
    assert_not user.marketplace_verified?
  end

  test "tampering expiry and changed profile identity do not create an account" do
    base = registration_attributes
    [ base.merge(directory_preview_token: base[:directory_preview_token] + "invalid"),
      base.merge(directory_profile_url: PROFILE_URL.sub("11111111", "22222222")) ].each do |attributes|
      assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
        post registration_path(locale: :en), params: { registration: attributes }
      end
      assert_response :unprocessable_content
      assert_includes response.body, I18n.t("signup_profile.errors.invalid_preview", locale: :en)
      assert_select "input[name='registration[directory_preview_token]'][value]", count: 0
    end
    travel 21.minutes do
      assert_no_difference "User.count" do
        post registration_path(locale: :en), params: { registration: base }
      end
      assert_response :unprocessable_content
    end
  end

  test "company details are unnecessary after importing a public professional profile" do
    assert_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ], 1 do
      post registration_path(locale: :en), params: { registration: registration_attributes.merge(firm_name: "", enterprise_number: "") }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, User.find_by!(email_address: "listed@example.test").primary_firm.name
  end

  test "an invalid preview retains the link and requires a new lookup" do
    attributes = registration_attributes.merge(directory_preview_token: "expired-or-invalid")
    post registration_path(locale: :en), params: { registration: attributes }
    assert_response :unprocessable_content
    assert_select "input[name='registration[first_name]'][value='Jane']"
    assert_select "input[name='registration[directory_profile_url]'][value='#{PROFILE_URL}']"
    assert_select "input[name='registration[email_address]']", count: 0

    assert_no_difference "User.count" do
      post registration_path(locale: :en), params: { registration: attributes.except(:directory_preview_token) }
    end
    assert_response :unprocessable_content

    assert_difference "User.count", 1 do
      post registration_path(locale: :en), params: { registration: registration_attributes }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal %w[NL FR], User.find_by!(email_address: "listed@example.test").lawyer_profile.spoken_languages
  end

  test "a corrected name keeps the signed listed email available without granting access" do
    attributes = registration_attributes.merge(last_name: "Another identity")
    assert_no_difference "User.count" do
      post registration_path(locale: :en), params: { registration: attributes }
    end
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t("signup_profile.review", locale: :en)
    assert_select "[data-registration-profile-target='summaryEmail']", text: "listed@example.test"
    assert_select "input[name='registration[directory_preview_token]'][value='#{attributes[:directory_preview_token]}']"
    assert_select "input[name='registration[email_address]']", count: 0
  end

  test "preview errors are localized and do not create accounts or jobs" do
    %i[nl fr de en].each do |locale|
      %i[invalid_url unavailable malformed email_missing].each do |status|
        result = @result.with(status:)
        Directory::SignupProfile.define_singleton_method(:call) { |**| result }
        assert_no_difference "User.count" do
          assert_no_enqueued_jobs do
            post registration_profile_path(locale:), params: { registration: { directory_profile_url: PROFILE_URL } }, as: :json
          end
        end
        assert_equal status.to_s, response.parsed_body["status"]
        assert_equal I18n.t("signup_profile.errors.#{status}", locale:), response.parsed_body["message"]
        assert_response status == :unavailable ? :service_unavailable : :unprocessable_content
      end
    end
  end

  test "cross-site preview submissions are rejected before fetching a profile" do
    previous = RegistrationsController.allow_forgery_protection
    RegistrationsController.allow_forgery_protection = true
    post registration_profile_path(locale: :en), params: { registration: { directory_profile_url: PROFILE_URL } },
      headers: { "Origin" => "https://unrelated.example" }, as: :json
    assert_response :unprocessable_content
    assert_empty @calls
  ensure
    RegistrationsController.allow_forgery_protection = previous
  end

  test "profile lookup limits do not consume the separate account-registration quota" do
    with_rate_counts do
      5.times do
        post registration_profile_path(locale: :en), params: { registration: { directory_profile_url: PROFILE_URL } }, as: :json
        assert_response :success
      end
      post registration_profile_path(locale: :en), params: { registration: { directory_profile_url: PROFILE_URL } }, as: :json
      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body["status"]
      assert_equal 5, @calls.size

      post registration_path(locale: :en), params: { registration: registration_attributes }
      assert_redirected_to verification_status_path(locale: :en)
    end
  end

  test "the shared daily lookup cap prevents another remote fetch" do
    with_rate_counts("rate-limit:registrations:directory_daily:all" => 500) do
      assert_no_enqueued_jobs do
        post registration_profile_path(locale: :en), params: { registration: { directory_profile_url: PROFILE_URL } }, as: :json
      end
      assert_response :too_many_requests
      assert_equal "limit_reached", response.parsed_body["status"]
      assert_empty @calls
    end
  end

  private

  def with_rate_counts(counts = {})
    store = RegistrationsController.cache_store
    original = store.method(:increment)
    store.define_singleton_method(:increment) do |key, amount = 1, **|
      counts[key] = counts.fetch(key, 0) + amount
    end
    yield
  ensure
    store.define_singleton_method(:increment, original) if store && original
  end

  def registration_attributes
    { first_name: "Jane", last_name: "van den Berg", email_address: "working@example.test",
      password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple",
      directory_profile_url: PROFILE_URL, directory_preview_token: Directory::SignupPreview.issue(@result),
      locale: "en", terms_accepted: "1" }
  end
end
