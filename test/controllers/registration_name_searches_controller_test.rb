require "test_helper"

class RegistrationNameSearchesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/00000000-0000-4000-8000-000000000001"

  setup do
    @original_search = Directory::AdvocaatBeNameSearch.method(:call)
    @original_profile = Directory::SignupProfile.method(:call)
    @calls = []
    calls = @calls
    @result = Directory::AdvocaatBeNameSearch::Result.new(status: :ok,
      candidates: [ { "name" => "Jane van den Berg", "profile_url" => PROFILE_URL, "location" => "1000 Brussel" } ], truncated: false)
    set_search_result(@result)
    @profile_calls = []
    profile_calls = @profile_calls
    @profile = Directory::SignupProfile::Result.new(status: :ok, profile_url: PROFILE_URL,
      name: "Jane van den Berg", first_name: "Jane", last_name: "van den Berg", email_address: "listed@example.test", profile_attributes: {})
    profile = @profile
    Directory::SignupProfile.define_singleton_method(:call) do |**arguments|
      profile_calls << arguments
      profile
    end
  end

  teardown do
    Directory::AdvocaatBeNameSearch.define_singleton_method(:call, @original_search)
    Directory::SignupProfile.define_singleton_method(:call, @original_profile)
  end

  test "anonymous name search exposes bounded public candidates without identity email or account creation" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        post registration_search_path(locale: :en), params: { registration: { name_query: "Jane", password: "never-echo-password" } }, as: :json
      end
    end
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "status" => "ok", "candidates" => @result.candidates, "truncated" => false }, response.parsed_body)
    assert_equal [ { name_query: "Jane" } ], @calls
    assert_empty @profile_calls
    assert_not_includes response.body, "email"
    assert_not_includes response.body, "never-echo-password"
    assert_not_includes response.body, "token"
  end

  test "HTML results retain the query but discard stale identity previews and passwords" do
    token = Directory::SignupPreview.issue(@profile)
    post registration_search_path(locale: :en), params: { registration: {
      name_query: "Jane", directory_profile_url: PROFILE_URL, directory_preview_token: token,
      password: "never-echo-password", password_confirmation: "never-echo-password"
    } }

    assert_response :success
    assert_includes response.body, "Jane van den Berg"
    assert_includes response.body, "1000 Brussel"
    assert_select "input[name='registration[directory_preview_token]'][value]", count: 0
    assert_select "fieldset[data-registration-profile-target='details'][hidden][disabled]", count: 2
    assert_not_includes response.body, "never-echo-password"
    assert_not_includes response.body, "listed@example.test"
    assert_empty @profile_calls
  end

  test "zero results and a capped result list remain normal search outcomes" do
    set_search_result(@result.with(candidates: []))
    post registration_search_path(locale: :nl), params: { registration: { name_query: "Absent" } }, as: :json
    assert_response :success
    assert_empty response.parsed_body.fetch("candidates")

    set_search_result(@result.with(truncated: true))
    post registration_search_path(locale: :nl), params: { registration: { name_query: "Lawyer" } }, as: :json
    assert_response :success
    assert response.parsed_body.fetch("truncated")
  end

  test "search errors are localized and do not reveal upstream or account details" do
    %i[nl fr de en].each do |locale|
      %i[invalid_query unavailable].each do |status|
        set_search_result(@result.with(status:, candidates: []))
        assert_no_difference "User.count" do
          assert_no_enqueued_jobs { post registration_search_path(locale:), params: { registration: { name_query: "Jane" } }, as: :json }
        end
        assert_response(status == :unavailable ? :service_unavailable : :unprocessable_content)
        assert_equal status.to_s, response.parsed_body.fetch("status")
        assert_equal I18n.t("signup_search.errors.#{status}", locale:), response.parsed_body.fetch("message")
      end
    end
  end

  test "missing structured input is treated as an invalid query" do
    set_search_result(@result.with(status: :invalid_query, candidates: []))
    [ {}, { registration: "Jane" }, { registration: { name_query: [ "Jane" ] } } ].each do |parameters|
      post registration_search_path(locale: :en), params: parameters, as: :json
      assert_response :unprocessable_content
      assert_nil @calls.last.fetch(:name_query)
    end
  end

  test "HTML result selection still fetches the canonical profile and creates only a signed preview" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      assert_no_enqueued_jobs do
        post registration_profile_path(locale: :en), params: { registration: {
          directory_profile_url: "https://untrusted.example/ignored", selected_profile_url: PROFILE_URL
        } }
      end
    end
    assert_response :success
    assert_equal [ { profile_url: PROFILE_URL } ], @profile_calls
    assert_select "input[name='registration[directory_preview_token]'][value]", count: 1
    assert_select "input[name='registration[directory_profile_url]'][value='#{PROFILE_URL}']"
    assert_select "input[name='username'][value='listed@example.test'][readonly]"
  end

  test "selected profile URLs go through authoritative validation rather than trusting search parameters" do
    Directory::SignupProfile.define_singleton_method(:call, @original_profile)
    post registration_profile_path(locale: :en), params: { registration: {
      selected_profile_url: "https://untrusted.example/profile", directory_profile_url: PROFILE_URL
    } }, as: :json

    assert_response :unprocessable_content
    assert_equal "invalid_url", response.parsed_body.fetch("status")
  end

  test "cross-site submissions are rejected before directory search" do
    previous = RegistrationsController.allow_forgery_protection
    RegistrationsController.allow_forgery_protection = true
    post registration_search_path(locale: :en), params: { registration: { name_query: "Jane" } },
      headers: { "Origin" => "https://unrelated.example" }, as: :json
    assert_response :unprocessable_content
    assert_empty @calls
  ensure
    RegistrationsController.allow_forgery_protection = previous
  end

  test "name searches have their own bounded client quota without consuming profile previews" do
    with_rate_counts do
      5.times do
        post registration_search_path(locale: :en), params: { registration: { name_query: "Jane" } }, as: :json
        assert_response :success
      end
      post registration_search_path(locale: :en), params: { registration: { name_query: "Jane" } }, as: :json
      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body.fetch("status")
      assert_equal 5, @calls.size

      post registration_profile_path(locale: :en), params: { registration: { directory_profile_url: PROFILE_URL } }, as: :json
      assert_response :success
    end
  end

  test "daily global cap blocks another name lookup before fetching" do
    with_rate_counts("rate-limit:registrations:directory_name_daily:all" => 200) do
      post registration_search_path(locale: :en), params: { registration: { name_query: "Jane" } }, as: :json
      assert_response :too_many_requests
      assert_equal "limit_reached", response.parsed_body.fetch("status")
      assert_empty @calls
    end
  end

  test "name queries are excluded from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ "registration" => { "name_query" => "[FILTERED]" } }, filter.filter("registration" => { "name_query" => "Jane van den Berg" }))
  end

  private

  def set_search_result(result)
    calls = @calls
    Directory::AdvocaatBeNameSearch.define_singleton_method(:call) do |**arguments|
      calls << arguments
      result
    end
  end

  def with_rate_counts(counts = {})
    store = RegistrationsController.cache_store
    original = store.method(:increment)
    store.define_singleton_method(:increment) { |key, amount = 1, **| counts[key] = counts.fetch(key, 0) + amount }
    yield
  ensure
    store.define_singleton_method(:increment, original) if store && original
  end
end
