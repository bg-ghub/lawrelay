require "test_helper"

class ReadinessControllerTest < ActionDispatch::IntegrationTest
  test "reports ready when the primary database responds" do
    get "/ready"

    assert_response :success
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "returns a generic service-unavailable response when local storage is not writable" do
    original_probe = ReadinessController.method(:storage_ready?)
    ReadinessController.define_singleton_method(:storage_ready?) do
      raise Errno::EACCES, "storage path leaked"
    end

    get "/ready"

    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable" }, response.parsed_body)
    assert_not_includes response.body, "storage path leaked"
  ensure
    ReadinessController.define_singleton_method(:storage_ready?, original_probe) if original_probe
  end

  test "returns a generic service-unavailable response when the database check fails" do
    original_probe = ReadinessController.method(:primary_database_ready?)
    ReadinessController.define_singleton_method(:primary_database_ready?) do
      raise ActiveRecord::ConnectionNotEstablished, "database password leaked"
    end

    get "/ready"

    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable" }, response.parsed_body)
    assert_not_includes response.body, "database password leaked"
  ensure
    ReadinessController.define_singleton_method(:primary_database_ready?, original_probe) if original_probe
  end
end
