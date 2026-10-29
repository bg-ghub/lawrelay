require "application_system_test_case"

class AccessibilityBetaTest < ApplicationSystemTestCase
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
