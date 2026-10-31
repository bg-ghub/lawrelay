require "application_system_test_case"

class SignupProfileTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @nonce = SecureRandom.hex(5)
    @profile_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}"
    @second_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}"
    @listed_email = "listed-#{@nonce}@example.test"
    @working_email = "working-#{@nonce}@example.test"
    @registered_emails = [ @listed_email, @working_email ]
    @pages = {
      @profile_url => profile_html("Jean Pierre Example", @listed_email),
      @second_url => profile_html("Grace Example", "second-#{@nonce}@example.test")
    }
    @gate = { unavailable: false, hold: false, calls: [], release: Queue.new }
    pages, gate = @pages, @gate
    @original_signup_fetch = Directory::SignupProfile.instance_method(:fetch_html)
    Directory::SignupProfile.define_method(:fetch_html) do |uri|
      gate[:calls] << uri.to_s
      gate[:release].pop if gate[:hold]
      gate[:unavailable] ? nil : pages.fetch(uri.to_s)
    end
    Directory::SignupProfile.send(:private, :fetch_html)
    @original_verification_fetch = Directory::AdvocaatBeProfileLookup.instance_method(:fetch_html)
    Directory::AdvocaatBeProfileLookup.define_method(:fetch_html) { |uri| pages.fetch(uri.to_s) }
    Directory::AdvocaatBeProfileLookup.send(:private, :fetch_html)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    @gate[:hold] = false
    @gate[:release] << true
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    Directory::SignupProfile.define_method(:fetch_html, @original_signup_fetch)
    Directory::SignupProfile.send(:private, :fetch_html)
    Directory::AdvocaatBeProfileLookup.define_method(:fetch_html, @original_verification_fetch)
    Directory::AdvocaatBeProfileLookup.send(:private, :fetch_html)
    users = User.where(email_address: @registered_emails)
    user_ids = users.pluck(:id)
    firm_ids = Membership.where(user_id: user_ids).pluck(:firm_id)
    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    users.delete_all
    Firm.where(id: firm_ids).delete_all
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
  end

  test "a profile supplies editable identity and preferences but never verifies an account" do
    visit_signup
    assert_no_selector "#registration_first_name", visible: :visible
    assert find("#registration_password", visible: :all).disabled?
    assert_no_difference [ "User.count", "Firm.count" ] do
      load_profile
    end
    assert_empty ActionMailer::Base.deliveries
    assert_selector ".registration-profile__summary", text: "Jean Pierre Example"
    assert_selector ".registration-profile__summary", text: @listed_email
    assert_no_selector "#registration_first_name", visible: :visible
    assert_no_selector "[name='registration[firm_name]'], [name='registration[enterprise_number]'], [name='registration[address_line_1]']", visible: :all
    assert_no_selector "[data-controller*='business-lookup']", visible: :all

    click_button "Edit details"
    fill_in "registration_first_name", with: "Jean Pierre"
    fill_in "registration_last_name", with: "Example"
    fill_in "registration_email_address", with: @working_email
    assert_not_empty find("#registration_directory_preview_token", visible: :all).value
    fill_credentials
    perform_enqueued_jobs do
      find("#registration_password_confirmation").send_keys(:enter)
      assert_current_path verification_status_path(locale: :en)
    end
    user = User.find_by!(email_address: @working_email)
    assert_equal "Jean Pierre", user.first_name
    assert_equal "Example", user.last_name
    assert_equal %w[NL FR], user.lawyer_profile.spoken_languages
    assert_equal [ "Family law" ], user.lawyer_profile.practice_areas
    assert user.lawyer_profile.directory_matched?
    assert_not user.email_verified?
    assert_not user.marketplace_verified?
    assert_nil user.lawyer_profile.directory_email_verified_at
    assert user.primary_firm.address_line_1.blank?
    assert_nil user.primary_firm.phone
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, user.primary_firm.name
    assert_nil user.primary_firm.enterprise_number
    assert_nil user.primary_firm.vat_number
    assert_nil user.primary_firm.billing_email
    assert_empty user.primary_firm.kbo_details
    assert ActionMailer::Base.deliveries.any? { |mail| mail.to == [ @working_email ] }
  end

  test "an unavailable directory leaves a manual signup path" do
    @gate[:unavailable] = true
    visit_signup
    load_profile(expect_success: false)
    assert_text I18n.t("signup_profile.errors.unavailable", locale: :en)
    assert_no_selector "#registration_password", visible: :visible
    click_button "Enter details manually"
    assert_field "registration_first_name", with: ""
    assert_field "registration_email_address", with: ""
    assert_field "registration_directory_profile_url", with: @profile_url
    assert_not find("#registration_password").disabled?
    assert_equal "", find("#registration_directory_preview_token", visible: :all).value
  end

  test "a late response cannot overwrite a changed profile link or manual identity" do
    visit_signup
    @gate[:hold] = true
    fill_in "registration_directory_profile_url", with: @profile_url
    click_button "Get profile details"
    assert_button "Loading…", disabled: true
    fill_in "registration_directory_profile_url", with: @second_url
    click_button "Enter details manually"
    fill_in "registration_first_name", with: "Keep my name"
    @gate[:hold] = false
    @gate[:release] << true
    assert_button "Get profile details", disabled: false
    assert_field "registration_directory_profile_url", with: @second_url
    assert_field "registration_first_name", with: "Keep my name"
    assert_equal "", find("#registration_directory_preview_token", visible: :all).value
    click_button "Get profile details"
    assert_text I18n.t("signup_profile.review", locale: :en)
    assert_field "registration_first_name", with: "Keep my name"
    assert_field "registration_email_address", with: "second-#{@nonce}@example.test"
    assert_equal "", find("#registration_directory_preview_token", visible: :all).value
  end

  test "import and manual identity survive Turbo back without replacing an edited email" do
    visit_signup
    load_profile
    click_button "Edit details"
    fill_in "registration_email_address", with: @working_email
    fill_in "registration_password", with: "Keep-this-password1!"
    find("a[href='#{new_session_path(locale: :en)}']", text: I18n.t("auth.actions.already_registered", locale: :en)).click
    assert_current_path new_session_path(locale: :en)
    page.go_back
    assert_current_path new_registration_path(locale: :en)
    assert_selector ".registration-profile__summary", text: @working_email
    assert_field "registration_password", with: ""
    click_button "Get profile details"
    assert_text I18n.t("signup_profile.loaded", locale: :en)
    assert_selector ".registration-profile__summary", text: @working_email
    click_button "Edit details"
    assert_field "registration_email_address", with: @working_email
  end

  test "Turbo back re-enables a profile lookup interrupted by navigation" do
    visit_signup
    @gate[:hold] = true
    fill_in "registration_directory_profile_url", with: @profile_url
    click_button "Get profile details"
    assert_button "Loading…", disabled: true
    find("a[href='#{new_session_path(locale: :en)}']", text: I18n.t("auth.actions.already_registered", locale: :en)).click
    assert_current_path new_session_path(locale: :en)
    @gate[:hold] = false
    @gate[:release] << true
    page.go_back
    assert_current_path new_registration_path(locale: :en)
    assert_button "Get profile details", disabled: false
    assert_field "registration_directory_profile_url", with: @profile_url
    click_button "Get profile details"
    assert_text I18n.t("signup_profile.loaded", locale: :en)
    assert_selector ".registration-profile__summary", text: "Jean Pierre Example"
  end

  test "all four languages fit a narrow screen before and after import" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 1000, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      visit_signup(locale:)
      assert_selector "html[lang='#{locale}']"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      page.save_screenshot(Rails.root.join("tmp/screenshots/signup-profile-initial-nl-320.png").to_s) if locale == :nl
      load_profile(locale:)
      assert_selector ".registration-profile__summary", text: "Jean Pierre Example"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_no_text(/translation missing/i)
      page.save_screenshot(Rails.root.join("tmp/screenshots/signup-profile-loaded-nl-320.png").to_s) if locale == :nl
      click_button I18n.t("signup_profile.edit", locale:)
      assert_field "registration_first_name", with: "Jean"
      assert_field "registration_email_address", with: @listed_email
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
    end
  end

  test "without JavaScript the preview button fills the ordinary form and signup remains pending" do
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit new_registration_path(locale: :en)
    assert_field "registration_first_name", with: ""
    fill_in "registration_directory_profile_url", with: @profile_url
    assert_no_difference [ "User.count", "Firm.count" ] do
      click_button "Get profile details"
      assert_current_path registration_profile_path(locale: :en)
      assert_field "registration_first_name", with: "Jean"
    end
    assert_field "registration_last_name", with: "Pierre Example"
    assert_field "registration_email_address", with: @listed_email
    assert_not_empty find("#registration_directory_preview_token", visible: :all).value
    assert_empty ActionMailer::Base.deliveries
    fill_credentials
    find("form.assignment-form input[type='submit']").click
    assert_current_path verification_status_path(locale: :en)
    user = User.find_by!(email_address: @listed_email)
    assert_equal %w[NL FR], user.lawyer_profile.spoken_languages
    assert_nil user.lawyer_profile.directory_profile_id
    assert_not user.email_verified?
    assert_not user.marketplace_verified?
  end

  private

  def visit_signup(locale: :en)
    visit new_registration_path(locale:)
    assert_button I18n.t("signup_profile.manual", locale:)
  end

  def load_profile(locale: :en, expect_success: true)
    fill_in "registration_directory_profile_url", with: @profile_url
    find("#registration_directory_profile_url").send_keys(:enter)
    if expect_success
      assert_text I18n.t("signup_profile.loaded", locale:)
      assert_not_empty find("#registration_directory_preview_token", visible: :all).value
    else
      assert_button I18n.t("signup_profile.fetch", locale:), disabled: false
    end
  end

  def fill_credentials
    fill_in "registration_password", with: "Synthetic-password1!"
    fill_in "registration_password_confirmation", with: "Synthetic-password1!"
    find("#registration_terms_accepted").check
  end

  def profile_html(name, email)
    <<~HTML
      <main id="main"><h1>#{name}</h1><a href="mailto:#{email}">Email</a>
        <h2>Talen</h2><p>Nederlands, Frans</p>
        <h2>Voorkeurmateries</h2><p>Family law</p>
        <h2>Contact</h2><address>Professional address 10<br>1000 Brussel</address>
        <a href="tel:+3225550100">Phone</a><h2>Derdenrekening</h2><p>Ignored bank details</p>
      </main>
    HTML
  end
end
