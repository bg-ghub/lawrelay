require "application_system_test_case"

class HomePathwayHighlightTest < ApplicationSystemTestCase
  IDS = %w[outsource-assignment find-assignments].freeze

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.current_window.resize_to(1400, 1400)
  end

  test "hero hover highlights only the corresponding destination despite a previous hash" do
    visit root_path(locale: :en, anchor: IDS.last)
    assert_selector("##{IDS.last}:target")
    page.execute_script("window.scrollTo({ top: 0, behavior: 'instant' })")

    IDS.each do |id|
      find(".hero-actions a[href='##{id}']").hover
      assert_highlighted(id)
      assert_not_highlighted((IDS - [ id ]).first)
    end
  end

  test "keyboard focus identifies the corresponding card and its entire link still navigates" do
    visit root_path(locale: :en)
    find(".hero-actions a[href='##{IDS.first}']").send_keys(:tab)

    assert_highlighted(IDS.last)
    assert_not_highlighted(IDS.first)
    find("##{IDS.last}").click
    assert_current_path new_session_path(locale: :en)
  end

  test "pointer hover takes precedence over retained keyboard focus" do
    visit root_path(locale: :en)
    find(".hero-actions a[href='##{IDS.first}']").send_keys(:tab)
    assert_highlighted(IDS.last)

    find(".hero-actions a[href='##{IDS.first}']").hover
    assert_highlighted(IDS.first)
    assert_not_highlighted(IDS.last)
  end

  test "mobile anchor taps retain the destination highlight without motion" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])

    IDS.each do |id|
      visit root_path(locale: :nl)
      find(".hero-actions a[href='##{id}']").click

      assert_current_path root_path(locale: :nl), ignore_query: true
      assert_selector("##{id}:target")
      assert_highlighted(id)
      assert_not_highlighted((IDS - [ id ]).first)
      assert_equal "none", find("##{id}").native.css_value("transform")
      assert_operator find("##{id}").native.css_value("transition-duration").to_f, :<=, 0.001
      assert page.evaluate_script("document.getElementById('#{id}').getBoundingClientRect().top < window.innerHeight")
    end
  end

  private

  def assert_highlighted(id)
    assert_selector("##{id}") { |node| node.native.css_value("outline-color") != "rgba(0, 0, 0, 0)" }
  end

  def assert_not_highlighted(id)
    assert_selector("##{id}") { |node| node.native.css_value("outline-color") == "rgba(0, 0, 0, 0)" }
  end
end
