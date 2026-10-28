require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # The browser server uses its own connection, so records set up for a system
  # test must be committed before the browser can read them.
  self.use_transactional_tests = false
end
