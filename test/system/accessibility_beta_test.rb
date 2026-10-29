require "application_system_test_case"

class AccessibilityBetaTest < ApplicationSystemTestCase
  test "Turbo progress styles are permitted by the content security policy" do
    visit root_path(locale: :en)
    assert_selector "header"

    assert page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("style")).some(style =>
        style.textContent.includes(".turbo-progress-bar") &&
        style.nonce === document.querySelector('meta[name="csp-nonce"]').content &&
        style.sheet !== null
      )
    JS
  end

  test "sign-in sidebar links have usable pointer targets in every language" do
    %w[nl fr de en].each do |locale|
      [ 390, 1440 ].each do |width|
        page.current_window.resize_to(width, 900)
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 900, deviceScaleFactor: 1, mobile: false)
        visit new_session_path(locale:)

        links = all(".posting-aside a")
        assert_equal 2, links.size
        links.each do |link|
          size = link.evaluate_script("({width: this.getBoundingClientRect().width, height: this.getBoundingClientRect().height})")
          assert_operator size.fetch("width"), :>=, 24, "#{locale} #{link.text} target width"
          assert_operator size.fetch("height"), :>=, 24, "#{locale} #{link.text} target height"
        end
      end
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
  end
end
