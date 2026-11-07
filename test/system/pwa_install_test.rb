require "application_system_test_case"

class PwaInstallTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ], options: { name: :pwa_install_mobile }

  # These tests exercise real DOM controls at a narrow viewport with a synthetic
  # beforeinstallprompt event. They do not prove native mobile or OS installation.
  setup do
    @previous_environment = ENV.slice("APP_HOST", "ADMIN_HOST", "APP_PROTOCOL")
    # Isolate the synthetic event from Chrome's real install promotion on loopback.
    # Observe trusted events without ever opening the native installation prompt.
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
      window.lawrelayPwaTrustedEvents = []
      window.addEventListener("beforeinstallprompt", (event) => {
        if (!event.isTrusted) return
        window.lawrelayPwaTrustedEvents.push({
          constructor: event.constructor.name,
          isTrusted: event.isTrusted,
          promptMethod: typeof event.prompt
        })
        event.preventDefault()
        event.stopImmediatePropagation()
      }, { capture: true })
    JS
    visit "/up"
    ENV["APP_HOST"] = URI.parse(page.current_url).host
    ENV["ADMIN_HOST"] = "admin.localhost"
    ENV["APP_PROTOCOL"] = "http"
    page.current_window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
    clear_install_dismissal
    visit root_path(locale: :en)
    assert_equal 390, page.evaluate_script("window.innerWidth")
    assert_equal 844, page.evaluate_script("window.innerHeight")
    assert_selector "[data-pwa-open-install]"
    assert_no_selector "[data-pwa-install-banner]"
  end

  teardown do
    clear_install_dismissal
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
  ensure
    %w[APP_HOST ADMIN_HOST APP_PROTOCOL].each do |key|
      @previous_environment.key?(key) ? ENV[key] = @previous_environment[key] : ENV.delete(key)
    end
  end

  def after_teardown
    super
  ensure
    # Keep this test's viewport, storage and worker registration out of other tests.
    page.driver.quit
  end

  test "the automatic install banner calls the browser prompt only when its actual Install button is clicked" do
    emit_synthetic_install_event

    assert_selector "[data-pwa-install-banner] [data-pwa-install]", text: "Install"
    assert_selector "[data-pwa-copy='native']", text: "Open LawRelay in its own window."
    assert_equal 0, prompt_calls
    assert_no_horizontal_overflow

    find("[data-pwa-install-banner] [data-pwa-install]").click

    assert_equal 1, prompt_calls
    assert_no_selector "[data-pwa-install-banner]"
    page.execute_script("window.lawrelayPwaTest.resolveChoice({ outcome: 'accepted' })")
    assert_no_selector "[data-pwa-open-install]"
  end

  test "closing manual footer help does not suppress a later automatic native Install button" do
    find("[data-pwa-open-install]").click
    assert_selector "[data-pwa-install-banner]"
    assert_no_selector "[data-pwa-install]"
    find("[data-pwa-dismiss]").click
    assert_no_selector "[data-pwa-install-banner]"

    emit_synthetic_install_event

    assert_selector "[data-pwa-install-banner] [data-pwa-install]", text: "Install"
    assert_equal 0, prompt_calls
    find("[data-pwa-install-banner] [data-pwa-install]").click
    assert_equal 1, prompt_calls
  end

  test "dismissing the real cookie controls reveals a captured automatic install banner" do
    # Test mode deliberately omits production analytics markup. Render the real
    # partial here without adding a website ID or making tracking requests.
    cookie_markup = I18n.with_locale(:en) { ApplicationController.render(partial: "shared/analytics_preference") }
    page.execute_script(<<~JS, cookie_markup)
      document.body.insertAdjacentHTML("beforeend", arguments[0])
      document.querySelector("[data-analytics-preference-panel]").hidden = false
    JS
    assert_selector "[data-analytics-preference-panel]"

    emit_synthetic_install_event

    assert_no_selector "[data-pwa-install-banner]"
    assert_equal 0, prompt_calls
    find("[data-analytics-dismiss-banner]").click

    assert_no_selector "[data-analytics-preference-panel]"
    assert_selector "[data-pwa-install-banner] [data-pwa-install]", text: "Install"
    assert_no_horizontal_overflow
    find("[data-pwa-install-banner] [data-pwa-install]").click
    assert_equal 1, prompt_calls
  end

  private

  def emit_synthetic_install_event
    page.execute_script(<<~JS)
      window.lawrelayPwaTest = { calls: 0 }
      const event = new Event("beforeinstallprompt", { cancelable: true })
      event.prompt = () => {
        window.lawrelayPwaTest.calls += 1
        return Promise.resolve()
      }
      event.userChoice = new Promise((resolve) => { window.lawrelayPwaTest.resolveChoice = resolve })
      window.dispatchEvent(event)
    JS
  end

  def prompt_calls
    page.evaluate_script("window.lawrelayPwaTest.calls")
  end

  def clear_install_dismissal
    page.execute_script(<<~JS)
      try {
        Object.keys(localStorage).filter((key) => key.startsWith("lawrelay_pwa_install_dismissed_at_")).forEach((key) => localStorage.removeItem(key))
      } catch (_) {
        // Capybara may already have reset the page to about:blank during cleanup.
      }
    JS
  end

  def assert_no_horizontal_overflow
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
  end
end
