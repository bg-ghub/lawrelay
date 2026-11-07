require "test_helper"

class PwaHelperTest < ActiveSupport::TestCase
  include PwaHelper

  test "installation is offered only on the configured member host" do
    previous_environment = ENV.slice("APP_HOST", "ADMIN_HOST")
    ENV["APP_HOST"] = "lawrelay.example"
    ENV["ADMIN_HOST"] = "admin.lawrelay.example"
    context = Object.new.extend(PwaHelper)
    context.define_singleton_method(:controller_path) { "home" }

    { "lawrelay.example" => true, "admin.lawrelay.example" => false,
      "www.lawrelay.example" => false, "lawrelay.example.evil.test" => false,
      "qa.localhost" => false }.each do |hostname, expected|
      request = Struct.new(:host).new(hostname)
      context.define_singleton_method(:request) { request }
      assert_equal expected, context.pwa_available?, hostname
    end

    context.define_singleton_method(:request) { Struct.new(:host).new("lawrelay.example") }
    context.define_singleton_method(:controller_path) { "admin/users" }
    refute context.pwa_available?
  ensure
    %w[APP_HOST ADMIN_HOST].each do |key|
      previous_environment.key?(key) ? ENV[key] = previous_environment[key] : ENV.delete(key)
    end
  end
end
