require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AuthenticatedAccessibilityTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "authenticatedaccessibility")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    @assignment = create_assignment_for(@account, title: "Keyboard notification check")
    26.times do |index|
      @account.user.notifications.create!(kind: "assignment_completed", subject: @assignment,
        data: { assignment_id: @assignment.id }, read_at: (Time.current unless index.zero?))
    end
    @original_import = Directory::ProfileImport.method(:call)
    Directory::ProfileImport.define_singleton_method(:call) do |**|
      Directory::ProfileImport::Result.new(status: :ok,
        profile_attributes: { spoken_languages: %w[NL FR] })
    end
    sign_in
  end

  teardown do
    Directory::ProfileImport.define_singleton_method(:call, @original_import)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    @account.user.notifications.delete_all
    @assignment.destroy!
    AuditEvent.where(actor_user_id: @account.user.id).delete_all
    @account.user.reload.destroy!
    @account.firm.reload.destroy!
  end

  test "settings import is keyboard reachable and labelled at narrow and desktop widths" do
    each_locale_and_width do |locale, width|
      visit settings_path(locale:)
      assert_accessible_document(locale, width)
      assert_selector "fieldset legend", count: 2
      assert_selector "button.profile-import-button", text: I18n.t("profile_import.button", locale:)
      assert_pointer_target(find(".profile-import-button"))

      find("a[href='#{@account.profile.directory_profile_url}']").send_keys(:tab)
      assert_equal "import_profile", active_element.attribute("value"), "#{locale} #{width}: import follows the profile link"
      assert_keyboard_focus_visible
      active_element.send_keys(:tab)
      assert_equal "profile[bar_admission_year]", active_element.attribute("id")
    end

    visit settings_path(locale: :en)
    find("a[href='#{@account.profile.directory_profile_url}']").send_keys(:tab)
    active_element.send_keys(:enter)
    assert_selector "form[data-unsaved-changes='true']", visible: :all
    assert_selector "[role='status']", text: "Details loaded. Review them, then save."
    assert_no_selector "[name^='firm[']", visible: :all
    assert_nil @account.firm.reload.phone
    assert_accessible_document(:en, 1440)
  end

  test "notification filters and pagination work with the keyboard in every language" do
    each_locale_and_width do |locale, width|
      visit notifications_path(locale:)
      assert_accessible_document(locale, width)
      assert_selector ".notification-center-list li", count: 25
      assert_selector ".notification-center-filters [aria-current='page']", text: I18n.t("notification_center.all", locale:)

      %w[.notification-center-filters\ a .notification-center-pagination\ a .notification-mark-all].each do |selector|
        all(selector).each { |control| assert_pointer_target(control) }
      end

      find(".notification-center-filters a[aria-current='page']").send_keys(:tab)
      assert_equal I18n.t("notification_center.unread", locale:), active_element.text
      assert_keyboard_focus_visible
      active_element.send_keys(:enter)
      assert_current_path notifications_path(locale:, filter: "unread")
      assert_selector ".notification-center-list li", count: 1
      assert_selector ".notification-center-filters [aria-current='page']", text: I18n.t("notification_center.unread", locale:)

      visit notifications_path(locale:)
      find(".notification-center-pagination a").send_keys(:enter)
      assert_current_path notifications_path(locale:, page: 2)
      assert_selector ".notification-center-list li", count: 1
      assert_selector ".notification-center-pagination a", text: I18n.t("notification_center.previous", locale:)
    end
    assert_equal 1, @account.user.notifications.unread.count

    visit notifications_path(locale: :en, filter: "unread")
    find(".notification-center-filters a[aria-current='page']").send_keys(:tab)
    assert_includes active_element.attribute("class"), "notification-mark-all"
    assert_keyboard_focus_visible
    active_element.send_keys(:enter)
    assert_text "You’re up to date"
    assert_selector ".notification-center-item", count: 0
    assert_accessible_document(:en, 1440)
    assert_empty @account.user.notifications.unread
  end

  private

  def sign_in
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  def each_locale_and_width
    %i[nl fr de en].each do |locale|
      [ 320, 1440 ].each do |width|
        page.current_window.resize_to(width, 1000)
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 1, mobile: false)
        yield locale, width
      end
    end
  end

  def active_element
    page.driver.browser.switch_to.active_element
  end

  def assert_keyboard_focus_visible
    assert page.evaluate_script(<<~JS)
      (() => {
        const element = document.activeElement;
        const style = getComputedStyle(element);
        return element.matches(':focus-visible') &&
          style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 2;
      })()
    JS
  end

  def assert_pointer_target(control)
    size = control.evaluate_script("({width: this.getBoundingClientRect().width, height: this.getBoundingClientRect().height})")
    assert_operator size.fetch("width"), :>=, 24, "#{control.text} target width"
    assert_operator size.fetch("height"), :>=, 24, "#{control.text} target height"
  end

  def assert_accessible_document(locale, width)
    assert_selector "html[lang='#{locale}']"
    assert_selector "main", count: 1
    assert_selector "h1", count: 1
    assert_equal width, page.evaluate_script("window.innerWidth")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
    assert_no_text(/translation missing/i)
    assert_no_selector "input:not([type='hidden']):not([type='submit']):not([type='button']):not([id])"
    run_axe_if_requested
  end

  # Set AXE_CORE_PATH for the local audit; CI needs no downloaded browser code.
  def run_axe_if_requested
    path = ENV["AXE_CORE_PATH"].presence
    return unless path

    page.driver.browser.execute_script(File.read(path))
    results = page.driver.browser.execute_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      // The branded logotype is exempt from WCAG text-contrast requirements.
      axe.run({ exclude: [['.site-header .brand']] }, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa', 'best-practice'] } })
        .then(result => done({ violations: result.violations.map(item => ({ id: item.id, targets: item.nodes.map(node => node.target) })) }))
        .catch(error => done({ error: error.message }));
    JS
    assert_nil results["error"]
    assert_empty results.fetch("violations"), results.to_json
  end
end
