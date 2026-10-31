require "test_helper"

class Operations::QueueHealthTest < ActiveSupport::TestCase
  # These are service query-contract tests with fakes, not queue database tests.
  test "a clear queue checks both wait thresholds using existence queries" do
    now = Time.zone.parse("2026-10-28 12:00:00")

    with_queue_queries do |queries|
      assert Operations::QueueHealth.healthy?(now:)
      assert_equal [
        [ :failed ],
        [ :ready, "created_at < ?", now - 15.minutes ],
        [ :scheduled, "scheduled_at < ?", now - 15.minutes ],
        [ :outbox, { now: now } ],
        [ :registry_alerts, { now: now } ]
      ], queries
    end
  end

  test "any failed execution makes the queue unhealthy without loading jobs" do
    with_queue_queries(failed: true) do |queries|
      assert_not Operations::QueueHealth.healthy?
      assert_equal [ [ :failed ] ], queries
    end
  end

  test "a ready execution older than the wait limit makes the queue unhealthy" do
    with_queue_queries(ready: true) do |queries|
      assert_not Operations::QueueHealth.healthy?
      assert_equal [ :failed, :ready ], queries.map(&:first)
    end
  end

  test "a scheduled execution past the due wait limit makes the queue unhealthy" do
    with_queue_queries(scheduled: true) do
      assert_not Operations::QueueHealth.healthy?
    end
  end

  test "failed or stale notification email makes the generic queue check unhealthy" do
    with_queue_queries(outbox: true) do
      assert_not Operations::QueueHealth.healthy?
    end
  end

  test "failed or stale registry alert makes the generic queue check unhealthy" do
    with_queue_queries(registry_alerts: true) do |queries|
      assert_not Operations::QueueHealth.healthy?
      assert_equal :registry_alerts, queries.last.first
    end
  end

  test "database failures at each query fail closed and log only the class" do
    original_logger = Rails.logger
    output = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(output)

    %i[failed ready scheduled outbox registry_alerts].each do |query|
      with_queue_queries(error_at: query) do
        assert_not Operations::QueueHealth.healthy?
      end
    end

    assert_equal 5, output.string.scan("Operational queue health check failed: ActiveRecord::StatementInvalid").length
    assert_not_includes output.string, "sensitive SQL and credentials"
  ensure
    Rails.logger = original_logger
  end

  private

  def with_queue_queries(failed: false, ready: false, scheduled: false, outbox: false, registry_alerts: false, error_at: nil)
    queries = []
    originals = {
      failed: [ SolidQueue::FailedExecution, :exists?, SolidQueue::FailedExecution.method(:exists?) ],
      ready: [ SolidQueue::ReadyExecution, :where, SolidQueue::ReadyExecution.method(:where) ],
      scheduled: [ SolidQueue::ScheduledExecution, :where, SolidQueue::ScheduledExecution.method(:where) ],
      outbox: [ Notification, :email_delivery_unhealthy?, Notification.method(:email_delivery_unhealthy?) ],
      registry_alerts: [ RegistryStatusRun, :alert_delivery_unhealthy?, RegistryStatusRun.method(:alert_delivery_unhealthy?) ]
    }
    outcomes = { failed:, ready:, scheduled:, outbox:, registry_alerts: }

    originals.each do |query, (model, method)|
      model.define_singleton_method(method) do |*arguments|
        queries << [ query, *arguments ]
        raise ActiveRecord::StatementInvalid, "sensitive SQL and credentials" if query == error_at

        if query.in?(%i[failed outbox registry_alerts])
          outcomes.fetch(query)
        else
          Object.new.tap do |relation|
            relation.define_singleton_method(:exists?) { outcomes.fetch(query) }
          end
        end
      end
    end

    yield queries
  ensure
    originals&.each_value do |model, method, implementation|
      model.define_singleton_method(method, implementation)
    end
  end
end
