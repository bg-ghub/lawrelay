require "application_system_test_case"

class HomePathwayHighlightTest < ApplicationSystemTestCase
  IDS = %w[outsource-assignment find-assignments].freeze

  # Headless CI has no physical mouse. Declare the input capabilities exercised
  # by these desktop tests; the mobile test overrides them with touch emulation.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: { name: :home_pathway_mouse } do |options|
    options.add_argument("--blink-settings=primaryPointerType=4,availablePointerTypes=4,primaryHoverType=2,availableHoverTypes=2")
  end

  def after_teardown
    super
  ensure
    # A fresh driver also prevents touch capability overrides leaking between
    # cases. Quit after Rails has captured any failure screenshot.
    page.driver.quit
  end

  test "hero hover highlights only the corresponding destination despite a previous hash" do
    visit root_path(locale: :en, anchor: IDS.last)
    assert_mouse_capabilities
    assert_selector("##{IDS.last}:target")
    assert_no_selector(".pathway-card:focus-visible")
    page.execute_script("window.scrollTo({ top: 0, behavior: 'instant' })")

    IDS.each do |id|
      find(".hero-actions a[href='##{id}']").hover
      assert_selector(".hero-actions a[href='##{id}']:hover")
      assert_highlighted(id)
      assert_not_highlighted((IDS - [ id ]).first)

      find(".hero-lede").hover
      IDS.each { |destination| assert_not_highlighted(destination) }
    end
  end

  test "keyboard focus identifies the corresponding card and its entire link still navigates" do
    visit root_path(locale: :en)
    find(".hero-actions a[href='##{IDS.first}']").send_keys(:tab)

    assert_highlighted(IDS.last)
    assert_not_highlighted(IDS.first)

    find(".hero-actions a[href='##{IDS.last}']").send_keys(:tab)
    assert_selector("##{IDS.first} .pathway-card:focus-visible")
    assert_highlighted(IDS.first)
    assert_not_highlighted(IDS.last)

    find("##{IDS.first} .pathway-card").send_keys(:tab)
    assert_selector("##{IDS.last} .pathway-card:focus-visible")
    assert_highlighted(IDS.last)
    assert_not_highlighted(IDS.first)
    find("##{IDS.last} .pathway-card").click
    assert_current_path new_session_path(locale: :en)
  end

  test "pointer hover takes precedence over retained keyboard focus" do
    visit root_path(locale: :en)
    assert_mouse_capabilities
    find(".hero-actions a[href='##{IDS.first}']").hover
    assert_selector(".hero-actions a[href='##{IDS.first}']:hover")
    find(".hero-actions a[href='##{IDS.first}']").send_keys(:tab)

    assert_selector(".hero-actions a[href='##{IDS.first}']:hover")
    assert_selector(".hero-actions a[href='##{IDS.last}']:focus-visible")
    assert_highlighted(IDS.first)
    assert_not_highlighted(IDS.last)
  end

  test "mobile anchor taps scroll without retaining a highlight or motion" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])

    IDS.each do |id|
      visit root_path(locale: :nl)
      assert page.evaluate_script("matchMedia('(hover: none) and (pointer: coarse)').matches"), "Expected a touch-only input device"
      find(".hero-actions a[href='##{id}']").click

      assert_current_path root_path(locale: :nl), ignore_query: true
      assert_selector("##{id}:target")
      IDS.each { |destination| assert_not_highlighted(destination) }
      assert_no_selector(".pathway-card:focus-visible")
      assert_equal "none", find("##{id} .pathway-card").native.css_value("transform")
      assert_operator find("##{id} .pathway-card").native.css_value("transition-duration").to_f, :<=, 0.001
      assert page.evaluate_script("document.getElementById('#{id}').getBoundingClientRect().top < window.innerHeight")
    end
  end

  private

  def assert_mouse_capabilities
    assert page.evaluate_script("matchMedia('(hover: hover) and (pointer: fine)').matches"), "Expected a hover-capable mouse input device"
  end

  def assert_highlighted(id)
    assert_selector("##{id} .pathway-card") { |node| node.native.css_value("outline-color") != "rgba(0, 0, 0, 0)" }
  end

  def assert_not_highlighted(id)
    assert_selector("##{id} .pathway-card") { |node| node.native.css_value("outline-color") == "rgba(0, 0, 0, 0)" }
  end
end
