require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class SearchableSelectTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @accounts = []
    @member = account("typeahead")
    @old_admin_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    sign_in(@member.user)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    @old_admin_id.nil? ? ENV.delete("LAWRELAY_ADMIN_USER_ID") : ENV["LAWRELAY_ADMIN_USER_ID"] = @old_admin_id
    user_ids = Array(@accounts).map { |record| record.user.id }
    firm_ids = Array(@accounts).map { |record| record.firm.id }
    assignment_ids = Assignment.where(firm_id: firm_ids).pluck(:id)
    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Notification.where(user_id: user_ids).delete_all
    Proposal.where(user_id: user_ids).or(Proposal.where(assignment_id: assignment_ids)).delete_all
    Assignment.where(id: assignment_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: firm_ids).delete_all
  end

  test "partial legal areas and subtypes select real values and preserve kind state" do
    visit new_assignment_path(locale: :en)
    field = find("#assignment_practice_area-search")
    field.set("ployment")
    assert_selector "#assignment_practice_area-options [role='option']", count: 1, exact_text: "Employment law"
    field.send_keys(:arrow_down, :enter)
    assert_native_value "assignment_practice_area", "Employment law"
    field.click
    assert_selector "#assignment_practice_area-options [role='option']", minimum: 2
    field.send_keys(:escape)
    assert_no_selector "#assignment_court_subtype", visible: :all

    find("label.kind-option", text: "Legal task").click
    assert_no_selector "#assignment-description-hint", visible: true
    assert_nil find("#assignment_description")["aria-describedby"]
    assert_not find("#assignment_legal_subtype-search").disabled?
    fill_in "assignment_legal_subtype-search", with: "tract"
    find("#assignment_legal_subtype-search").send_keys(:arrow_down, :enter)
    assert_native_value "assignment_legal_subtype", "contract"
    find("label.kind-option", text: "Court cover").click
    assert_selector "#assignment-description-hint", visible: true
    assert_equal "assignment-description-hint", find("#assignment_description")["aria-describedby"]
    assert find("#assignment_legal_subtype-search", visible: :all).disabled?
    find("label.kind-option", text: "Legal task").click
    assert_field "assignment_legal_subtype-search", with: I18n.t("marketplace.assignment_subtypes.contract", locale: :en)
  end

  test "Other legal area reveals a required custom field and predefined choices hide it" do
    visit new_assignment_path(locale: :en)
    assert_no_selector "#assignment_practice_area_other", visible: true
    field = find("#assignment_practice_area-search")
    field.set("oth")
    field.send_keys(:arrow_down, :enter)
    assert_native_value "assignment_practice_area", Assignment::OTHER_CHOICE
    assert_selector "#assignment_practice_area_other[required]"
    assert_equal "assignment_practice_area_other", page.driver.browser.switch_to.active_element.attribute("id")
    fill_in "assignment_practice_area_other", with: "Synthetic specialist field"
    choose_searchable_option("assignment_practice_area", label: "Employment law")
    assert_no_selector "#assignment_practice_area_other", visible: true
    assert find("#assignment_practice_area_other", visible: :all).disabled?
    choose_searchable_option("assignment_practice_area", value: Assignment::OTHER_CHOICE)
    assert_field "assignment_practice_area_other", with: "Synthetic specialist field"
    page.execute_script("document.querySelector('form.assignment-form').reset()")
    assert_no_selector "#assignment_practice_area_other", visible: true
    assert find("#assignment_practice_area_other", visible: :all).disabled?
  end

  test "a custom legal area survives validation errors and saves its entered name" do
    title = "Synthetic custom area #{SecureRandom.hex(4)}"
    visit new_assignment_path(locale: :en)
    find("label.kind-option", text: "Legal task").click
    fill_in "assignment_title", with: title
    fill_in "assignment_description", with: "A synthetic assignment without client or case details."
    choose_searchable_option("assignment_practice_area", value: Assignment::OTHER_CHOICE)
    fill_in "assignment_practice_area_other", with: "   "
    choose_searchable_option("assignment_legal_subtype", value: "advice")
    fill_in "assignment_languages", with: "EN"
    set_datetime("assignment_response_deadline_at", 1.day.from_now)
    set_datetime("assignment_execution_deadline", 3.days.from_now)
    find("#assignment_content_rules_accepted").check
    click_button I18n.t("marketplace.form.submit", locale: :en)
    assert_selector ".form-error[role='alert']:focus"
    assert_native_value "assignment_practice_area", Assignment::OTHER_CHOICE
    assert_field "assignment_practice_area_other", with: "   "
    assert_not Assignment.exists?(title:)

    fill_in "assignment_practice_area_other", with: "  Maritime mediation  "
    click_button I18n.t("marketplace.form.submit", locale: :en)
    assert_selector "h1", text: title
    assert_equal "Maritime mediation", Assignment.find_by!(title:).practice_area
  end

  test "holding the scrollbar keeps a searchable select open and preserves its scroll position" do
    visit new_assignment_path(locale: :en)
    find("#assignment_practice_area-search").click
    list = find("#assignment_practice_area-options")
    page.execute_script("arguments[0].scrollIntoView({block: 'center', behavior: 'instant'})", list)
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const list = document.querySelector('#assignment_practice_area-options')
        const bounds = list.getBoundingClientRect()
        return { x: Math.round(bounds.right - 8), y: Math.round(bounds.top + 20), scrollable: list.scrollHeight > list.clientHeight }
      })()
    JS
    assert geometry.fetch("scrollable")
    begin
      page.driver.browser.action.move_to_location(geometry.fetch("x"), geometry.fetch("y"))
        .click_and_hold.move_by(0, 100, duration: 0.5).perform
      assert_selector "#assignment_practice_area-search[aria-expanded='true']"
      assert_operator page.evaluate_script("document.querySelector('#assignment_practice_area-options').scrollTop"), :>, 0
    ensure
      page.driver.browser.action.release.perform
    end
    assert_selector "#assignment_practice_area-search[aria-expanded='true']"
    assert_operator page.evaluate_script("document.querySelector('#assignment_practice_area-options').scrollTop"), :>, 0
    page.save_screenshot(Rails.root.join("tmp/screenshots/searchable-select-scrollbar.png").to_s)
    fill_in "assignment_practice_area-search", with: "ployment"
    find("#assignment_practice_area-search").send_keys(:arrow_down, :enter)
    assert_native_value "assignment_practice_area", "Employment law"
  end

  test "unselected text never submits an old value and validation focuses the visible input" do
    visit new_privacy_request_path(locale: :en)
    choose_searchable_option("privacy_request_kind", value: "access_export")
    fill_in "privacy_request_details", with: "Synthetic request only."
    field = find("#privacy_request_kind-search")
    field.set("not-an-existing-choice")
    assert_text I18n.t("searchable_select.empty", locale: :en)
    assert_nil find("#privacy_request_kind", visible: :all).value.presence
    count = @member.user.privacy_requests.count
    click_button I18n.t("trust.privacy_requests.new.submit", locale: :en)
    assert_equal count, @member.user.privacy_requests.count
    assert_equal field[:id], page.driver.browser.switch_to.active_element.attribute("id")
    assert_not page.evaluate_script("document.getElementById('privacy_request_kind-search').checkValidity()")

    field.send_keys(:escape)
    assert_native_value "privacy_request_kind", "access_export"
    field.set("")
    click_button I18n.t("trust.privacy_requests.new.submit", locale: :en)
    assert_equal count, @member.user.privacy_requests.count
    assert_equal field[:id], page.driver.browser.switch_to.active_element.attribute("id")
  end

  test "member forms filters and translated areas accept partial input on narrow screens" do
    owner = account("typeahead-owner")
    assignment = create_assignment_for(owner)
    %i[nl fr de en].each do |locale|
      visit new_assignment_path(locale:)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 1000, deviceScaleFactor: 1, mobile: false)
      area = I18n.t("marketplace.practice_areas.tax", locale:)
      fill_in "assignment_practice_area-search", with: I18n.transliterate(area).downcase[1..]
      assert_selector "#assignment_practice_area-options [role='option']", exact_text: area
      find("#assignment_practice_area-options [role='option']", exact_text: area).click
      assert_native_value "assignment_practice_area", area
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    visit settings_path(locale: :en)
    fill_in "account_locale-search", with: "franc"
    find("#account_locale-search").send_keys(:arrow_down, :enter)
    assert_native_value "account[locale]", "fr"

    visit new_assignment_report_path(assignment, locale: :en)
    fill_in "report_category-search", with: "lead"
    find("#report_category-search").send_keys(:arrow_down, :enter)
    assert_native_value "report_category", "misleading"
    visit assignment_path(assignment, locale: :en)
    fill_in "proposal_rate_kind-search", with: "hour"
    find("#proposal_rate_kind-search").send_keys(:arrow_down, :enter)
    assert_native_value "proposal_rate_kind", "hourly"

    visit assignments_path(locale: :en)
    fill_in "city-search", with: "russ"
    find("#city-search").send_keys(:arrow_down, :enter)
    assert_field "city-search", with: "Brussels"
    assert_current_path(/city=Brussels/)
    assert_equal "Brussels", Rack::Utils.parse_query(URI(page.current_url).query)["city"]
  end

  test "reset native fallback and Turbo history preserve defaults and selections" do
    visit new_assignment_path(locale: :en)
    choose_searchable_option("assignment_practice_area", label: "Commercial law")
    page.execute_script("document.querySelector('form.assignment-form').reset()")
    assert_field "assignment_practice_area-search", with: ""
    assert_native_value "assignment_practice_area", ""
    visit settings_path(locale: :en)
    choose_searchable_option("account[locale]", value: "fr")
    find("a[href='#{privacy_requests_path(locale: :en)}']").click
    assert_current_path privacy_requests_path(locale: :en)
    page.go_back
    assert_field "account_locale-search", with: "Français"

    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit new_assignment_path(locale: :en)
    assert_selector "select#assignment_practice_area", visible: true
    assert_no_selector "#assignment_practice_area-search"
    find("#assignment_practice_area option", text: "Commercial law").select_option
    assert_native_value "assignment_practice_area", "Commercial law"
  end

  test "admin filters and account language accept partial input behind MFA" do
    admin = account("typeahead-admin", system_role: "admin")
    ENV["LAWRELAY_ADMIN_USER_ID"] = admin.user.id.to_s
    secret = admin.user.begin_admin_mfa_setup!
    admin.user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    admin.user.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    Capybara.reset_sessions!
    visit admin_login_path(locale: :en)
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path admin_mfa_challenge_path(locale: :en)
    fill_in "mfa_code", with: ROTP::TOTP.new(secret, issuer: "LawRelay").now
    click_button I18n.t("mfa.challenge.submit", locale: :en)
    assert_current_path admin_users_path(locale: :en)
    fill_in "status-search", with: "spend"
    find("#status-search").send_keys(:arrow_down, :enter)
    assert_native_value "status", "suspended"
    fill_in "verification-search", with: "ject"
    find("#verification-search").send_keys(:arrow_down, :enter)
    assert_native_value "verification", "rejected"
    visit admin_user_path(@member.user, locale: :en)
    fill_in "user_locale-search", with: "deut"
    find("#user_locale-search").send_keys(:arrow_down, :enter)
    assert_native_value "user_locale", "de"
  end

  private

  def account(prefix, **options)
    create_marketplace_account(prefix:, **options).tap { |record| @accounts << record }
  end

  def sign_in(user)
    visit new_session_path(locale: :en)
    fill_in "email_address", with: user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  def assert_native_value(id, value)
    assert_selector("select[id='#{id}']", visible: :all) { |select| select.value == value }
  end

  def set_datetime(id, value)
    page.execute_script(<<~JS, id, value.strftime("%Y-%m-%dT%H:%M"))
      const input = document.getElementById(arguments[0])
      input.value = arguments[1]
      input.dispatchEvent(new Event('input', {bubbles: true}))
      input.dispatchEvent(new Event('change', {bubbles: true}))
    JS
  end
end
