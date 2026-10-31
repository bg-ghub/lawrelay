require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class CourtPickerTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "courtpicker")
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
    visit new_assignment_path(locale: :en)
    assert_selector "[data-controller='court-picker'][data-court-picker-options-value]"
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    if @account
      AuditEvent.where(actor_user_id: @account.user.id).delete_all
      @account.user.destroy!
      @account.firm.destroy!
    end
  end

  test "court list filters by partial type place and accents and fills a real division" do
    assert_no_selector "#assignment_city", visible: :visible
    find("#assignment_court").click
    assert_selector "#assignment-court-options [role='option']:not([data-other])", count: 320
    assert_selector "#assignment-court-options [role='option'][data-other='true']", text: "Other"
    fill_in "assignment_court", with: "antwerpen"
    assert_selector "#assignment-court-options [role='option']", minimum: 10
    page.execute_script("document.querySelector('#assignment_court').scrollIntoView({block: 'center', behavior: 'instant'})")
    page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-desktop.png").to_s)
    fill_in "assignment_court", with: "entreprise anvers malines"

    expected = "Enterprise court Antwerp — division Mechelen"
    assert_selector "#assignment-court-options [role='option']:not([data-other])", count: 1, text: expected
    find("#assignment-court-options [role='option']", text: expected).click
    assert_field "assignment_court", with: expected
    assert_field "assignment_city", with: "Mechelen", visible: :all
    assert_no_selector "#assignment_city", visible: :visible
    assert_equal "Mechelen", page.evaluate_script("new FormData(document.querySelector('.assignment-form')).get('assignment[city]')")
    page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-selected-desktop.png").to_s)
    assert_selector "#assignment_court[aria-expanded='false']"

    fill_in "assignment_court", with: "liege police"
    assert_field "assignment_city", with: "", visible: :all, disabled: true
    assert_no_selector "#assignment_city", visible: :visible
    assert_selector "#assignment-court-options [role='option']", text: "Police court Liège — division Liège"
    find("#assignment_court").send_keys(:arrow_down, :enter)
    assert_match(/Police court Liège/, find("#assignment_court").value)
    assert_not_empty find("#assignment_city", visible: :all).value
    assert_no_selector "#assignment_city", visible: :visible

    fill_in "assignment_court", with: "Politierechtbank Brussel (Nederlandstalig)"
    assert_field "assignment_city", with: "Brussels", visible: :all
    assert_no_selector "#assignment_city", visible: :visible
  end

  test "a held native scrollbar stays open and permits selection after dragging" do
    find("#assignment_court").click
    list = find("#assignment-court-options")
    page.execute_script("arguments[0].scrollIntoView({block: 'center', behavior: 'instant'})", list)
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const list = document.querySelector('#assignment-court-options')
        const rect = list.getBoundingClientRect()
        return { x: Math.round(rect.right - 8), y: Math.round(rect.top + 20), scrollable: list.scrollHeight > list.clientHeight }
      })()
    JS
    assert geometry.fetch("scrollable")
    begin
      page.driver.browser.action.move_to_location(geometry.fetch("x"), geometry.fetch("y"))
        .click_and_hold.move_by(0, 120, duration: 0.5).perform
      assert_selector "#assignment_court[aria-expanded='true']"
      assert_operator page.evaluate_script("document.querySelector('#assignment-court-options').scrollTop"), :>, 0
    ensure
      page.driver.browser.action.release.perform
    end

    assert_selector "#assignment_court[aria-expanded='true']"
    assert_operator page.evaluate_script("document.querySelector('#assignment-court-options').scrollTop"), :>, 0
    visible_option = page.evaluate_script(<<~JS)
      (() => {
        const list = document.querySelector('#assignment-court-options')
        const bounds = list.getBoundingClientRect()
        return Array.from(list.children).find(option => {
          const rect = option.getBoundingClientRect()
          return rect.top >= bounds.top && rect.bottom <= bounds.bottom
        }).textContent
      })()
    JS
    find("#assignment-court-options [role='option']", text: visible_option, exact_text: true).click
    assert_field "assignment_court", with: visible_option
    assert_no_selector "#assignment_city", visible: :visible
  end

  test "keyboard dismissal explicit Other and kind switches preserve the normal form" do
    fill_in "assignment_court", with: "enterprise court mechelen"
    find("#assignment_court").send_keys(:arrow_down)
    assert_selector "#assignment_court[aria-activedescendant]"
    find("#assignment_court").send_keys(:escape)
    assert_selector "#assignment_court[aria-expanded='false']"
    assert_field "assignment_court", with: "enterprise court mechelen"

    fill_in "assignment_court", with: "Synthetic notary office"
    assert_text "No results. Choose Other to enter a venue."
    assert_equal "", page.evaluate_script("new FormData(document.querySelector('.assignment-form')).get('assignment[court_selection]')")
    assert_not page.evaluate_script("document.querySelector('#assignment_court').checkValidity()")
    find("#assignment-court-options [data-other='true']").click
    assert_field "assignment_court_other", with: ""
    assert_not page.evaluate_script("document.querySelector('#assignment_court_other').checkValidity()")
    fill_in "assignment_court_other", with: "Synthetic notary office"
    fill_in "assignment_city", with: "Test city"
    assert_field "assignment_court", with: "Other"
    assert_equal "__other__", page.evaluate_script("new FormData(document.querySelector('.assignment-form')).get('assignment[court_selection]')")

    find("label.kind-option", text: "Legal task").click
    assert_no_selector "#assignment_court", visible: :visible
    find("label.kind-option", text: "Court cover").click
    assert_field "assignment_court", with: "Other"
    assert_field "assignment_court_other", with: "Synthetic notary office"
    assert_field "assignment_city", with: "Test city"
  end

  test "an existing manual venue restores Other and its saved location" do
    original_new = AssignmentsController.instance_method(:new)
    AssignmentsController.define_method(:new) do
      original_new.bind_call(self)
      @assignment.assign_attributes(court: "Synthetic existing venue", city: "Existing city")
    end

    visit new_assignment_path(locale: :en)
    assert_field "assignment_court", with: "Other"
    assert_field "assignment_court_other", with: "Synthetic existing venue"
    assert_field "assignment_city", with: "Existing city"
    assert_selector "#assignment_court_other[required]"
    assert_selector "#assignment_city[required]"
    assert_equal "__other__", page.evaluate_script("new FormData(document.querySelector('.assignment-form')).get('assignment[court_selection]')")
  ensure
    AssignmentsController.define_method(:new, original_new) if original_new
  end

  test "locales show their court types and language-specific Brussels options on narrow screens" do
    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)

    %i[nl fr de en].each do |locale|
      visit new_assignment_path(locale:)
      fill_in "assignment_court", with: "police bruxelles"
      options = all("#assignment-court-options [role='option']:not([data-other])")
      assert_equal 2, options.size
      assert options.all? { |option| option.text.include?(I18n.t("court_picker.types.police", locale:)) }
      if locale == :nl
        page.execute_script("document.querySelector('#assignment_court').scrollIntoView({block: 'center', behavior: 'instant'})")
        page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-nl-320.png").to_s)
      end
      find("#assignment_court").send_keys(:arrow_down, :enter)
      assert_field "assignment_city", with: { nl: "Brussel", fr: "Bruxelles", de: "Brüssel", en: "Brussels" }.fetch(locale), visible: :all
      assert_no_selector "#assignment_city", visible: :visible
      page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-selected-nl-320.png").to_s) if locale == :nl
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_no_text(/translation missing/i)
      find("#assignment_court").click
      find("#assignment-court-options [data-other='true']").click
      assert_field I18n.t("court_picker.other_label", locale:)
      assert_field "assignment_city"
      assert_selector "#assignment_court_other[required]"
      assert_selector "#assignment_city[required]"
      page.save_screenshot(Rails.root.join("tmp/screenshots/court-picker-other-nl-320.png").to_s) if locale == :nl
    end
  end
end
