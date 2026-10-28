ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # SQLite uses one database file and does not provide reliable concurrent
    # transactional fixtures. Keep the default deterministic; CI can opt into
    # parallel workers after moving the test database to PostgreSQL.
    parallelize(workers: ENV.fetch("TEST_WORKERS", "1").to_i)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
