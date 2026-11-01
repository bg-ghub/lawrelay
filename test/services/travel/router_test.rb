require "test_helper"

class TravelRouterTest < ActiveSupport::TestCase
  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_path

    def initialize(body, response_class: Net::HTTPOK)
      @response = response_class.new("1.1", "200", "OK")
      @response.define_singleton_method(:read_body) { |&block| block.call(body) }
    end

    def start
      yield self
    end

    def request(request)
      @request_path = request.path
      yield @response
    end
  end

  setup do
    @origin = Travel::AddressIndex::Point.new(latitude: 50.85, longitude: 4.35)
    @destination = Travel::AddressIndex::Point.new(latitude: 50.9, longitude: 4.4)
  end

  test "only internal fixed endpoints are accepted" do
    %w[http://routing:5000 http://lawrelay-routing:5000 http://127.0.0.1:5000].each do |endpoint|
      assert Travel::Router.new(endpoint:).available?
    end
    [ "", "https://evil.example", "http://routing:5000/path", "http://user:password@routing:5000", "http://routing:5000?url=evil" ].each do |endpoint|
      assert_not Travel::Router.new(endpoint:).available?
    end
  end

  test "bounded local route returns driving distance and time without geometry or client details" do
    client = FakeHTTP.new(route_json)
    with_client(client) do
      route = router.route(origin: @origin, destination: @destination)
      assert_equal 38_001, route.distance_meters
      assert_equal 2101, route.duration_seconds
    end
    assert_includes client.request_path, "/driving/4.35,50.85;4.4,50.9"
    assert_includes client.request_path, "overview=false"
    assert_equal 1, client.open_timeout
    assert_equal 2, client.read_timeout
    assert_equal 0, client.max_retries
  end

  test "missing remote failed malformed oversized and far snapped responses are unavailable" do
    [ "{}", "broken json", "x" * (Travel::Router::MAX_BODY_BYTES + 1),
      route_json(code: "NoRoute"), route_json(distance: -1), route_json(duration: 100_000),
      route_json(snap: 500), route_json(distance: "38000") ].each do |body|
      with_client(FakeHTTP.new(body)) { assert_nil router.route(origin: @origin, destination: @destination) }
    end
    with_client(FakeHTTP.new(route_json, response_class: Net::HTTPMovedPermanently)) do
      assert_nil router.route(origin: @origin, destination: @destination)
    end
  end

  test "invalid coordinates are rejected before opening any connection" do
    invalid = Travel::AddressIndex::Point.new(latitude: 90, longitude: 4.35)
    assert_nil router.route(origin: invalid, destination: @destination)
    assert_nil router.route(origin: nil, destination: @destination)
  end

  test "the total request budget stops a trickling response even before a read timeout" do
    client = FakeHTTP.new(route_json)
    response = client.instance_variable_get(:@response)
    response.define_singleton_method(:read_body) do |&block|
      block.call("{")
      sleep 0.05
      block.call("}")
    end
    budgets = []
    original = Timeout.method(:timeout)
    Timeout.define_singleton_method(:timeout) do |seconds, &block|
      budgets << seconds
      original.call(0.01, &block)
    end
    with_client(client) { assert_nil router.route(origin: @origin, destination: @destination) }
    assert_equal [ 4 ], budgets
  ensure
    Timeout.define_singleton_method(:timeout, original) if original
  end

  private

  def router
    Travel::Router.new(endpoint: "http://routing:5000")
  end

  def route_json(code: "Ok", distance: 38_000.5, duration: 2100.6, snap: 10)
    { code:, routes: [ { distance:, duration: } ], waypoints: [ { distance: snap }, { distance: snap } ] }.to_json
  end

  def with_client(client)
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*| client }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original)
  end
end
