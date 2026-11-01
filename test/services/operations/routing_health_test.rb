require "test_helper"

class OperationsRoutingHealthTest < ActiveSupport::TestCase
  class Index
    attr_accessor :available

    def initialize(available: true)
      @available = available
    end

    def available? = available
  end

  class Router
    attr_accessor :available, :route_result, :error
    attr_reader :calls

    def initialize
      @available = true
      @route_result = Travel::Router::Route.new(distance_meters: 8_000, duration_seconds: 600)
      @calls = []
    end

    def available? = available

    def route(origin:, destination:)
      @calls << [ origin, destination ]
      raise error if error

      route_result
    end
  end

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @index = Index.new
    @router = Router.new
  end

  test "disabled routing is healthy without touching the index router or cache" do
    unused = Object.new

    assert Operations::RoutingHealth.healthy?(endpoint: nil, index_path: nil, index: unused, router: unused, cache: unused)
    assert Operations::RoutingHealth.healthy?(endpoint: " ", index_path: "", index: unused, router: unused, cache: unused)
  end

  test "partial configuration fails closed without making a route request" do
    assert_not healthy?(endpoint: "")
    assert_not healthy?(index_path: "")
    assert_empty @router.calls
  end

  test "missing local data or an invalid internal endpoint is unhealthy without a request" do
    @index.available = false
    assert_not healthy?
    assert_empty @router.calls

    @cache.clear
    @index.available = true
    @router.available = false
    assert_not healthy?
    assert_empty @router.calls
  end

  test "external routing providers are not used by the operational probe" do
    assert_not Operations::RoutingHealth.healthy?(index: @index, cache: @cache,
      endpoint: "https://unapproved-routing.example", index_path: "/private/local-osm.sqlite3")
  end

  test "a fixed public Belgian probe is reused for sixty seconds without customer data" do
    assert healthy?
    assert healthy?
    assert_equal 1, @router.calls.length
    origin, destination = @router.calls.sole
    assert_equal [ 50.85, 4.35 ], [ origin.latitude, origin.longitude ]
    assert_equal [ 50.9, 4.4 ], [ destination.latitude, destination.longitude ]

    @router.route_result = nil
    assert healthy?
    travel 61.seconds do
      assert_not healthy?
    end
    assert_equal 2, @router.calls.length
  end

  test "an unsuccessful probe is cached for sixty seconds and then can recover" do
    @router.route_result = nil
    assert_not healthy?
    @router.route_result = Travel::Router::Route.new(distance_meters: 8_000, duration_seconds: 600)
    assert_not healthy?
    assert_equal 1, @router.calls.length

    travel 61.seconds do
      assert healthy?
    end
    assert_equal 2, @router.calls.length
  end

  test "configuration changes do not reuse a previously healthy cache entry" do
    assert healthy?
    assert_not healthy?(endpoint: "")
    assert_not healthy?(index_path: "")
    assert_equal 1, @router.calls.length
  end

  test "unexpected local failures return only false" do
    @router.error = IOError.new("private local provider detail")

    assert_equal false, healthy?
    @router.error = nil
    assert_equal false, healthy?
    assert_equal 1, @router.calls.length
  end

  private

  def healthy?(**options)
    Operations::RoutingHealth.healthy?(index: @index, router: @router, cache: @cache,
      endpoint: "http://routing:5000", index_path: "/private/local-osm.sqlite3", **options)
  end
end
