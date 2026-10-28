require "test_helper"

class OperationalHealthControllerTest < ActionDispatch::IntegrationTest
  test "an anonymous probe gets only the healthy status" do
    with_queue_health(true) { get "/health/operations" }

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "an unhealthy queue returns only a generic unavailable status" do
    with_queue_health(false) { get "/health/operations" }

    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable" }, response.parsed_body)
  end

  test "a queue database error fails closed without exposing details" do
    original = SolidQueue::FailedExecution.method(:exists?)
    SolidQueue::FailedExecution.define_singleton_method(:exists?) do |*|
      raise ActiveRecord::ConnectionNotEstablished, "sensitive queue database details"
    end

    get "/health/operations"

    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable" }, response.parsed_body)
    assert_not_includes response.body, "sensitive"
    assert_not_includes response.body, "ConnectionNotEstablished"
  ensure
    SolidQueue::FailedExecution.define_singleton_method(:exists?, original) if original
  end

  private

  def with_queue_health(result)
    original = Operations::QueueHealth.method(:healthy?)
    Operations::QueueHealth.define_singleton_method(:healthy?) { |**| result }
    yield
  ensure
    Operations::QueueHealth.define_singleton_method(:healthy?, original) if original
  end
end
