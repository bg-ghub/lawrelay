require "application_system_test_case"

class LazyControllerLoadingTest < ApplicationSystemTestCase
  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
  end

  test "public navigation loads only its controllers and Turbo forms load controllers when needed" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 900, deviceScaleFactor: 1, mobile: false)
    visit root_path(locale: :en)
    find(".menu-toggle").click
    assert_selector "#primary-navigation.is-open"
    find(".menu-toggle").click
    assert_no_selector "#primary-navigation.is-open"
    find(".language-menu summary").click
    find(".language-menu summary").send_keys(:escape)
    assert_no_selector ".language-menu[open]"

    public_requests = requested_controllers
    assert_includes public_requests, "mobile_nav"
    assert_includes public_requests, "language_menu"
    declared = page.evaluate_script(<<~'JS')
      [...document.querySelectorAll('[data-controller]')].flatMap(element =>
        element.dataset.controller.split(/\s+/).map(name => name.replaceAll('-', '_'))
      )
    JS
    assert_empty public_requests.uniq - declared
    unused = %w[registration_profile assignment_kind searchable_select travel_estimate geo_challenge form_errors]
    unused.each do |controller|
      assert_not_includes public_requests, controller
      assert_no_selector "link[rel='modulepreload'][href*='/controllers/#{controller}_controller']", visible: :all
    end

    page.execute_script("window.lazyControllerDocument = 'preserved'")
    within ".site-footer" do
      click_link I18n.t("product_pages.links.court_cover", locale: :en)
    end
    assert_current_path court_cover_path(locale: :en)
    assert_equal "preserved", page.evaluate_script("window.lazyControllerDocument")
    assert_not_includes requested_controllers, "registration_profile"
    within ".product-page__actions" do
      click_link I18n.t("product_pages.actions.register", locale: :en)
    end
    assert_current_path new_registration_path(locale: :en)
    assert_equal "preserved", page.evaluate_script("window.lazyControllerDocument")
    assert_selector "button[data-registration-profile-target='search'][type='button']"
    fill_in "registration_name_query", with: "ab"
    find("button[data-registration-profile-target='search']").click
    assert_text I18n.t("signup_search.errors.invalid_query", locale: :en)
    assert_includes requested_controllers, "registration_profile"

    page.execute_script(<<~JS)
      const errors = document.createElement('div');
      errors.id = 'lazy-controller-errors';
      errors.tabIndex = -1;
      errors.textContent = 'Validation error';
      errors.dataset.controller = 'form-errors';
      document.querySelector('form.assignment-form').append(errors);
    JS
    assert_selector "#lazy-controller-errors:focus"
    assert_includes requested_controllers, "form_errors"
  end

  private

  def requested_controllers
    page.evaluate_script(<<~'JS')
      performance.getEntriesByType('resource').map(entry =>
        new URL(entry.name).pathname.match(/\/controllers\/([^/]+)_controller-[^/]+\.js$/)?.[1]
      ).filter(Boolean)
    JS
  end
end
