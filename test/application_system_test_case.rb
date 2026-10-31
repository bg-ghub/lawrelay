require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # The browser server uses its own connection, so records set up for a system
  # test must be committed before the browser can read them.
  self.use_transactional_tests = false

  def choose_searchable_option(id, value: nil, label: nil)
    source = find("select[id='#{id}']", visible: :all)
    option = source.all("option", visible: :all).find do |candidate|
      value.nil? ? candidate.text(:all) == label : candidate[:value] == value
    end
    assert option, "Expected option #{value || label} in #{id}"
    expected = option[:value]
    text = option.text(:all)
    control = source.find(:xpath, "..")
    input = control.find("input[role='combobox']")
    input.click
    input.set(text)
    control.find("[role='listbox'] [role='option']", exact_text: text).click
    assert_selector("select[id='#{id}']", visible: :all) { |select| select.value == expected }
  end
end
