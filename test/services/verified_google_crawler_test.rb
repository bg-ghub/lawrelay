require "test_helper"

class VerifiedGoogleCrawlerTest < ActiveSupport::TestCase
  ADDRESS = "66.249.66.1"
  CRAWLER_HOST = "crawl-66-249-66-1.googlebot.com"

  class FakeResolver
    attr_accessor :timeouts, :names, :addresses, :error, :delay, :completed
    attr_reader :reverse_calls, :forward_calls

    def initialize(names: [], addresses: {})
      @names, @addresses = names, addresses
      @reverse_calls, @forward_calls = [], []
    end

    def open
      yield self
    end

    def getnames(address)
      @reverse_calls << address
      raise error if error
      if delay
        sleep delay
        self.completed = true
      end
      names
    end

    def getaddresses(hostname)
      @forward_calls << hostname
      addresses.fetch(hostname, [])
    end
  end

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @resolver = FakeResolver.new(names: [ CRAWLER_HOST ], addresses: { "#{CRAWLER_HOST}." => [ ADDRESS ] })
  end

  test "Googlebot and InspectionTool require matching reverse and forward Google DNS" do
    [ "Googlebot/2.1", "Mozilla/5.0 (compatible; Google-InspectionTool/1.0;)" ].each do |agent|
      @cache.clear
      assert verify(user_agent: agent)
    end
    assert_equal [ ADDRESS, ADDRESS ], @resolver.reverse_calls
    assert_equal [ "#{CRAWLER_HOST}.", "#{CRAWLER_HOST}." ], @resolver.forward_calls
  end

  test "geographic Googlebot and Google controlled proxy hostnames are allowed" do
    [ "geo-crawl-66-249-66-1.geo.googlebot.com", "google-proxy-66-249-66-1.google.com" ].each do |hostname|
      @cache.clear
      @resolver.names = [ hostname.upcase + "." ]
      @resolver.addresses = { "#{hostname}." => [ ADDRESS ] }
      assert verify
    end
  end

  test "unrecognized or social preview agents do not trigger DNS even for a cached Google IP" do
    assert verify
    [ "", "Mozilla/5.0", "FakeGooglebot", "LinkedInBot", "GoogleOther", "AdsBot-Google" ].each do |agent|
      assert_not verify(user_agent: agent)
    end
    assert_equal 1, @resolver.reverse_calls.size
  end

  test "a spoofed Google agent without Google reverse DNS is refused" do
    @resolver.names = [ "visitor.example" ]
    assert_not verify
    assert_empty @resolver.forward_calls
  end

  test "forged reverse DNS must also resolve forward to the requesting address" do
    @resolver.addresses = { "#{CRAWLER_HOST}." => [ "203.0.113.9" ] }
    assert_not verify
  end

  test "lookalike suffixes arbitrary Google hosts and user controlled Google Cloud are refused" do
    [ "#{CRAWLER_HOST}.example", "crawl-examplegooglebot.com", "google-proxy-1.google.com.example",
      "arbitrary.google.com", "vm.googleusercontent.com", "crawl-1.googlebot.com\n" ].each do |hostname|
      @cache.clear
      @resolver.names = [ hostname ]
      @resolver.addresses = { "#{hostname}." => [ ADDRESS ] }
      assert_not verify
    end
    assert_empty @resolver.forward_calls
  end

  test "IPv6 and IPv4 mapped IPv6 are compared by normalized address" do
    @resolver.addresses = { "#{CRAWLER_HOST}." => [ "::ffff:66.249.66.1" ] }
    assert verify(ip: "::ffff:66.249.66.1")
    assert_equal ADDRESS, @resolver.reverse_calls.last

    @cache.clear
    @resolver.addresses = { "#{CRAWLER_HOST}." => [ "2001:4860:4801:10::1" ] }
    assert verify(ip: "2001:4860:4801:0010:0000:0000:0000:0001")
    assert_equal "2001:4860:4801:10::1", @resolver.reverse_calls.last
  end

  test "invalid CIDR scoped and local addresses never trigger DNS" do
    [ "invalid", "66.249.66.1/24", "fe80::1%eth0", "127.0.0.1", "::1", "10.0.0.1", "fe80::1" ].each do |address|
      assert_not verify(ip: address)
    end
    assert_empty @resolver.reverse_calls
  end

  test "positive and negative verification results expire and DNS failures fail closed" do
    assert verify
    @resolver.error = Resolv::ResolvTimeout.new
    travel 23.hours do
      assert verify
      assert_equal 1, @resolver.reverse_calls.size
    end
    travel 25.hours do
      assert_not verify
      assert_equal 2, @resolver.reverse_calls.size
      @resolver.error = nil
      assert_not verify
      assert_equal 2, @resolver.reverse_calls.size
    end
    travel 25.hours + 6.minutes do
      assert verify
      assert_equal 3, @resolver.reverse_calls.size
    end
  end

  test "the total DNS time limit interrupts a slow resolver and caches the refusal" do
    @resolver.delay = VerifiedGoogleCrawler::DNS_TIMEOUT + 1
    assert_not verify
    assert_not @resolver.completed
    assert_not verify
    assert_equal 1, @resolver.reverse_calls.size
  end

  private

  def verify(ip: ADDRESS, user_agent: "Googlebot/2.1")
    VerifiedGoogleCrawler.call(ip:, user_agent:, cache: @cache, resolver: @resolver)
  end
end
