require "application_system_test_case"

class SignupNameSearchTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @urls = %w[11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222].map do |id|
      "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{id}"
    end
    @candidates = @urls.each_with_index.map do |url, index|
      { "name" => "Jane Smith", "profile_url" => url, "location" => index.zero? ? "9000 Gent" : "2000 Antwerpen" }
    end
    @gate = { hold: false, release: Queue.new, queries: [], profiles: [], profile_hold: false, profile_release: Queue.new, profile_finished: [] }
    gate, candidates, urls = @gate, @candidates, @urls
    @original_search = Directory::AdvocaatBeNameSearch.method(:call)
    Directory::AdvocaatBeNameSearch.define_singleton_method(:call) do |name_query:, **|
      gate[:queries] << name_query
      gate[:release].pop if gate[:hold]
      Directory::AdvocaatBeNameSearch::Result.new(status: name_query == "Unavailable" ? :unavailable : :ok,
        candidates: name_query == "Nobody" ? [] : candidates, truncated: false)
    end
    @original_profile = Directory::SignupProfile.method(:call)
    Directory::SignupProfile.define_singleton_method(:call) do |profile_url:, **|
      gate[:profiles] << profile_url
      gate[:profile_release].pop if gate[:profile_hold] && profile_url == urls.first
      index = urls.index(profile_url)
      gate[:profile_finished] << profile_url
      Directory::SignupProfile::Result.new(status: :ok, profile_url:, name: "Jane Smith", first_name: "Jane", last_name: "Smith",
        email_address: "listed-#{index}@example.test", profile_attributes: {})
    end
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    @gate[:hold] = false
    @gate[:release] << true
    @gate[:profile_hold] = false
    @gate[:profile_release] << true
    Directory::AdvocaatBeNameSearch.define_singleton_method(:call, @original_search)
    Directory::SignupProfile.define_singleton_method(:call, @original_profile)
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
  end

  test "name results require choosing the correct location before the authoritative profile is loaded" do
    visit new_registration_path(locale: :en)
    assert_selector "input[name='registration[name_query]'][autocomplete='off']"
    assert_no_selector "#registration_directory_profile_url", visible: :visible
    assert_no_difference [ "User.count", "Firm.count", "LawyerProfile.count" ] do
      search_for("Smith")
      assert_selector ".registration-search__candidate", count: 2
      assert_empty @gate[:profiles]
      find(".registration-search__candidate", text: "2000 Antwerpen").click
      assert_field "registration_username", with: "listed-1@example.test", readonly: true
    end
    assert_equal [ @urls.last ], @gate[:profiles]
    assert_selector "input[name='username'][autocomplete='username']"
    assert_not_empty find("#registration_directory_preview_token", visible: :all).value
    assert find("#registration_password").value.empty?
    assert_empty ActionMailer::Base.deliveries
    assert_no_enqueued_jobs
    fill_in "registration_name_query", with: "Another name"
    assert_equal "", find("#registration_directory_preview_token", visible: :all).value
    assert_no_selector "#registration_password", visible: :visible
    assert_no_text I18n.t("signup_profile.stale", locale: :en)
    search_for("Smith")
    assert_selector ".registration-search__candidate", count: 2
    assert_no_text I18n.t("signup_profile.stale", locale: :en)
  end

  test "empty and failed searches retain name and allow the independent profile link fallback" do
    visit new_registration_path(locale: :en)
    search_for("Nobody")
    assert_text I18n.t("signup_search.empty", locale: :en)
    assert_no_selector ".registration-search__candidate"
    search_for("Unavailable")
    assert_text I18n.t("signup_search.errors.unavailable", locale: :en)
    assert_field "registration_name_query", with: "Unavailable"
    assert_button "Search Advocaat.be", disabled: false
    fill_in "registration_name_query", with: "Ab"
    find(".registration-search__fallback summary").click
    fill_in "registration_directory_profile_url", with: @urls.first
    click_button "Get profile details"
    assert_field "registration_username", with: "listed-0@example.test", readonly: true
    assert page.evaluate_script("document.getElementById('registration_name_query').validity.valid"), "An optional short search query must not block the profile-link path"
    assert_empty ActionMailer::Base.deliveries
  end

  test "a profile without a public location remains selectable" do
    @candidates.first["location"] = nil
    visit new_registration_path(locale: :en)
    search_for("Smith")
    assert_selector ".registration-search__candidate", count: 2
    candidate = find(".registration-search__candidate[data-profile-url='#{@urls.first}']")
    within(candidate) { assert_no_selector ".registration-search__location" }
    candidate.send_keys(:enter)
    assert_field "registration_username", with: "listed-0@example.test", readonly: true
  end

  test "a late name search cannot display results after the query changes" do
    visit new_registration_path(locale: :en)
    @gate[:hold] = true
    fill_in "registration_name_query", with: "Smith"
    click_button "Search Advocaat.be"
    assert_button "Searching…", disabled: true
    fill_in "registration_name_query", with: "Another"
    @gate[:hold] = false
    @gate[:release] << true
    assert_button "Search Advocaat.be", disabled: false
    assert_no_selector ".registration-search__candidate"
    assert_equal "", find("#registration_directory_preview_token", visible: :all).value
    search_for("Smith")
    assert_selector ".registration-search__candidate", count: 2
  end

  test "name search and explicit selection also work without JavaScript" do
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit new_registration_path(locale: :en)
    assert_no_difference [ "User.count", "Firm.count" ] do
      search_for("Smith")
      assert_current_path registration_search_path(locale: :en)
      find(".registration-search__candidate", text: "9000 Gent").click
      assert_current_path registration_profile_path(locale: :en)
      assert_field "registration_username", with: "listed-0@example.test", readonly: true
    end
    assert_not_empty find("#registration_directory_preview_token", visible: :all).value
    assert_empty ActionMailer::Base.deliveries
  end

  test "choosing another result while a profile loads cannot bind the earlier email" do
    visit new_registration_path(locale: :en)
    search_for("Smith")
    @gate[:profile_hold] = true
    find(".registration-search__candidate", text: "9000 Gent").click
    assert_selector "[data-registration-profile-target='fetch'][aria-busy='true']", visible: :all
    find(".registration-search__candidate", text: "2000 Antwerpen").click
    assert_field "registration_username", with: "listed-1@example.test", readonly: true
    @gate[:profile_hold] = false
    @gate[:profile_release] << true
    assert_selector("#registration_username") { @gate[:profile_finished].include?(@urls.first) }
    assert_field "registration_username", with: "listed-1@example.test", readonly: true
    assert_equal @urls.last, find("#registration_directory_profile_url", visible: :all).value
  end

  test "Turbo back restores a usable search after navigating away during a request" do
    visit new_registration_path(locale: :en)
    @gate[:hold] = true
    fill_in "registration_name_query", with: "Smith"
    click_button "Search Advocaat.be"
    assert_button "Searching…", disabled: true
    find(".registration-profile__signin a").click
    assert_current_path new_session_path(locale: :en)
    @gate[:hold] = false
    @gate[:release] << true
    page.go_back
    assert_current_path new_registration_path(locale: :en)
    assert_button "Search Advocaat.be", disabled: false
    assert_no_selector ".registration-search__candidate"
    search_for("Smith")
    assert_selector ".registration-search__candidate", count: 2
  end

  test "search results and selected details fit at 320 pixels in all four languages" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 1000, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      visit new_registration_path(locale:)
      search_for("Smith", locale:)
      assert_selector ".registration-search__candidate", count: 2
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      find(".registration-search__candidate", text: "2000 Antwerpen").click
      assert_field "registration_username", with: "listed-1@example.test", readonly: true
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_no_text(/translation missing/i)
    end
  end

  private

  def search_for(query, locale: :en)
    fill_in "registration_name_query", with: query
    click_button I18n.t("signup_search.submit", locale:)
  end
end
