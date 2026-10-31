require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class MarketplaceFlowTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  teardown :remove_system_test_records

  test "signing in preserves the requested locale and destination" do
    account = create_system_account("signin")

    visit new_assignment_path(locale: :fr)

    fill_in "email_address", with: account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click

    assert_current_path new_assignment_path(locale: :fr)
    assert_text "Nouvelle mission"
  end

  test "court cover hides language while a legal task reveals it" do
    account = create_system_account("kind")
    sign_in_through_browser(account.user)

    visit new_assignment_path(locale: :en)

    assert_no_selector "#assignment_languages", visible: :visible
    find("label.kind-option", text: "Legal task").click
    assert_selector "#assignment_languages", visible: :visible
    assert_not find("#assignment_languages").disabled?
    find("label.kind-option", text: "Court cover").click
    assert_no_selector "#assignment_languages", visible: :visible
  end

  test "a verified lawyer can post a safe court-cover assignment" do
    account = create_system_account("post")
    sign_in_through_browser(account.user)

    visit new_assignment_path(locale: :en)
    fill_in "assignment_title", with: "System-test court cover"
    fill_in "assignment_description", with: "A safe summary without client or matter information."
    choose_searchable_option("assignment_practice_area", label: "Commercial law")
    set_datetime("assignment_response_deadline_at", 2.days.from_now)
    set_datetime("assignment_hearing_at", 3.days.from_now)
    fill_in "assignment_duration_minutes", with: "60"
    find("#assignment_court").click
    find("#assignment-court-options [role='option'][data-other='true']").click
    fill_in "assignment_court_other", with: "Enterprise Court"
    fill_in "assignment_city", with: "Brussels"
    assert_no_selector "#assignment_court_subtype", visible: :all
    assert_no_selector "input[name^='assignment[invoice_']", visible: :all
    find("#assignment_content_rules_accepted").check

    click_button "Post assignment"

    assert_text "System-test court cover"
    assert_equal 1, Assignment.where(title: "System-test court cover").count
    assert_nil Assignment.find_by!(title: "System-test court cover").fee_cents
    assert_selector ".proposal-panel__price strong", text: "To be agreed"
    assert_nil Assignment.find_by!(title: "System-test court cover").assignment_subtype
    assert_text I18n.t("company_minimization.private_invoice_details", locale: :en)
  end

  test "an unrelated lawyer is sent back to the board for a closed assignment" do
    owner = create_system_account("closed-owner")
    outsider = create_system_account("closed-outsider")
    assignment = create_assignment_for(owner, title: "Closed private assignment", status: "completed")
    sign_in_through_browser(outsider.user)

    visit assignment_path(assignment, locale: :en)

    assert_current_path assignments_path(locale: :en)
    assert_no_text "Closed private assignment"
  end

  test "mobile navigation and the language picker support keyboard dismissal" do
    page.current_window.resize_to(390, 844)
    visit root_path(locale: :en)

    menu_button = find(".menu-toggle")
    assert_equal "primary-navigation", menu_button["aria-controls"]
    menu_button.send_keys(:enter)
    assert_selector ".menu-toggle[aria-expanded='true']"
    assert_equal "How it works", page.driver.browser.switch_to.active_element.text
    page.driver.browser.switch_to.active_element.send_keys(:escape)
    assert_selector ".menu-toggle[aria-expanded='false']"
    assert_equal menu_button.native, page.driver.browser.switch_to.active_element

    find(".language-menu summary").send_keys(:enter)
    assert_selector ".language-menu[open]"
    find(".language-menu summary").send_keys(:tab)
    assert_equal "Nederlands", page.driver.browser.switch_to.active_element.text.split.last
    page.driver.browser.switch_to.active_element.send_keys(:escape)
    assert_no_selector ".language-menu[open]"
    assert_equal "summary", page.driver.browser.switch_to.active_element.tag_name
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "public pages have one main landmark and fit narrow viewports in all languages" do
    %i[nl fr de en].each do |locale|
      [ 320, 800, 1280 ].each do |width|
        page.current_window.resize_to(width, 900)
        visit new_registration_path(locale:)

        assert_selector "html[lang='#{locale}']"
        assert_equal 1, all("main", visible: :all).size
        assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth"), "Registration overflows at #{width}px in #{locale}"
        all("form.assignment-form input:not([type='hidden']):not([type='submit'])").each do |field|
          assert field.native.accessible_name.present?, "Missing accessible input label for #{field[:id]}"
        end
      end
    end
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "keyboard users can skip the header and see which assignment kind has focus" do
    account = create_system_account("keyboard")
    sign_in_through_browser(account.user)
    visit new_assignment_path(locale: :en)

    find(".skip-link", visible: :all).send_keys(:enter)
    assert_equal "main-content", page.driver.browser.switch_to.active_element.attribute("id")

    court_kind = find("input[value='court_replacement']", visible: :all)
    court_kind.send_keys(:space)
    assert_equal court_kind.native, page.driver.browser.switch_to.active_element
    assert_selector ".kind-option:has(input:focus-visible)"
    court_kind.send_keys(:right)
    assert find("input[value='legal_task']", visible: :all).checked?
    assert_selector "#assignment_languages", visible: :visible
  end

  test "legal navigation fits a 320 pixel viewport in every language" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      visit legal_notice_path(locale:)
      assert_selector ".legal-navigation a", count: 4
      assert_no_selector ".legal-navigation a[href$='/pricing']"
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "registration validation moves focus to the error summary" do
    email = "system-invalid-#{SecureRandom.hex(5)}@example.test"
    original = Directory::SignupProfile.instance_method(:fetch_html)
    Directory::SignupProfile.define_method(:fetch_html) do |_uri|
      "<main id='main'><h1>Test Lawyer</h1><a href='mailto:#{email}'>Email</a></main>"
    end
    Directory::SignupProfile.send(:private, :fetch_html)
    visit new_registration_path(locale: :en)
    fill_in "registration_directory_profile_url", with: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
    click_button I18n.t("signup_profile.fetch", locale: :en)
    assert_text email
    fill_in "registration_password", with: "password1234"
    fill_in "registration_password_confirmation", with: "anotherpass12"
    find("#registration_terms_accepted").check
    find("form.assignment-form input[type='submit']").click

    assert_selector ".form-error[role='alert']"
    assert_includes page.driver.browser.switch_to.active_element.attribute("class"), "form-error"
  ensure
    Directory::SignupProfile.define_method(:fetch_html, original) if original
    Directory::SignupProfile.send(:private, :fetch_html)
  end

  private

  def create_system_account(prefix)
    token = "system-#{prefix}-#{SecureRandom.hex(5)}"
    (@system_test_tokens ||= []) << token
    create_marketplace_account(prefix: token)
  end

  def sign_in_through_browser(user)
    visit new_session_path(locale: :en)
    fill_in "email_address", with: user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  def set_datetime(id, time)
    value = time.strftime("%Y-%m-%dT%H:%M")
    page.execute_script(<<~JAVASCRIPT, id, value)
      const input = document.getElementById(arguments[0]);
      input.value = arguments[1];
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    JAVASCRIPT
  end

  def remove_system_test_records
    tokens = @system_test_tokens || []
    return if tokens.empty?

    users = User.where(tokens.map { |token| "email_address LIKE ?" }.join(" OR "), *tokens.map { |token| "#{token}%" })
    user_ids = users.pluck(:id)
    firm_ids = Membership.where(user_id: user_ids).pluck(:firm_id)
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
end
