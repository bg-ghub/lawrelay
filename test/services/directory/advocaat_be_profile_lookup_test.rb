require "test_helper"

class AdvocaatBeProfileLookupTest < ActiveSupport::TestCase
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
  MOVED_URL = PROFILE_URL.sub("63fee2a5", "73fee2a5")

  def html(name: "Jane Lawyer", email: "jane@example.test")
    <<~HTML
      <html><body><h1>Cookie settings</h1><main id="main"><h1>#{name}</h1><a href="mailto:#{email}">Email</a></main></body></html>
    HTML
  end

  test "only accepts official HTTPS profile URLs" do
    result = Directory::AdvocaatBeProfileLookup.call(profile_url: "https://evil.example/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a", full_name: "Jane Lawyer")

    assert_equal :invalid_url, result.status
    refute Directory::AdvocaatBeProfileLookup.valid_profile_url?("#{PROFILE_URL}?next=https://evil.example")
    refute Directory::AdvocaatBeProfileLookup.valid_profile_url?("https://www.advocaat.be:444/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    assert_equal PROFILE_URL, Directory::AdvocaatBeProfileLookup.canonical_profile_url(PROFILE_URL.sub("www.", ""))
  end

  test "an unavailable provider returns no identity evidence" do
    result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher: ->(_) { nil })

    assert_equal :unavailable, result.status
  end

  test "one official permanent redirect returns the final verified identity and its original UUID" do
    %w[301 308].each do |code|
      calls = []
      fetcher = lambda do |uri|
        calls << uri.to_s
        calls.size == 1 ? [ code, URI(MOVED_URL).path ] : html
      end
      result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher:)

      assert result.success?
      assert_equal [ PROFILE_URL, MOVED_URL ], calls
      assert_equal MOVED_URL, result.source_url
      assert_equal MOVED_URL.split("/").last, result.profile_id
      assert_equal PROFILE_URL.split("/").last, result.original_profile_id
      assert_equal "jane@example.test", result.email
    end
  end

  test "a moved profile still needs the requested name and a valid listed mailbox" do
    [ [ html(name: "Another Person"), :name_mismatch ], [ html(email: ""), :email_missing ],
      [ html + html, :malformed ], [ [ 404, nil ], :unavailable ] ].each do |response, expected|
      fetcher = ->(uri) { uri.to_s == PROFILE_URL ? [ 301, MOVED_URL ] : response }
      result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher:)
      assert_equal expected, result.status
      assert_nil result.original_profile_id
      assert_nil result.profile_id
      assert_nil result.source_url
    end
  end

  test "uses the heading and mailto within main content only" do
    result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher: ->(_) { html })

    assert result.success?
    assert_equal "Jane Lawyer", result.name
    assert_equal "jane@example.test", result.email
    assert_equal "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a", result.source_url
  end

  test "does not accept a name mismatch or a missing professional email" do
    mismatch = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Someone Else", fetcher: ->(_) { html })
    missing_email = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher: ->(_) { html(email: "") })

    assert_equal :name_mismatch, mismatch.status
    assert_equal :email_missing, missing_email.status
  end

  test "missing and removed HTTP profiles are permanent invalid links" do
    [ Net::HTTPNotFound.new("1.1", "404", "Not Found"), Net::HTTPGone.new("1.1", "410", "Gone") ].each do |response|
      with_http_response(response) do |client|
        result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer")

        assert_equal :invalid_url, result.status
        assert_nil result.name
        assert_nil result.email
        assert_equal 1, client.requests.size
      end
    end
  end

  test "provider failures and redirects stay unavailable without following a new endpoint" do
    [ Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable"), Net::HTTPFound.new("1.1", "302", "Found") ].each do |response|
      response["location"] = "https://different.example/profile"
      with_http_response(response) do |client|
        result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer")

        assert_equal :unavailable, result.status
        assert_equal 1, client.requests.size
        assert_equal URI(PROFILE_URL).request_uri, client.requests.first.path
      end
    end
  end

  test "HTTP parsing retains verified TLS and the streamed response limit" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/html"
    response.define_singleton_method(:read_body) { |&block| block.call(html_body) }
    response.define_singleton_method(:html_body) { '<main id="main"><h1>Jane Lawyer</h1><a href="mailto:jane@example.test">Email</a></main>' }
    with_http_response(response) do |client|
      assert Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer").success?
      assert client.use_ssl
      assert_equal OpenSSL::SSL::VERIFY_PEER, client.verify_mode
      assert_equal 5, client.open_timeout
      assert_equal 8, client.read_timeout
    end

    chunks_read = 0
    chunks = [ "a" * Directory::AdvocaatBeProfileLookup::MAX_BODY_BYTES, "overflow", "must not be read" ]
    response.define_singleton_method(:read_body) do |&block|
      chunks.each do |chunk|
        chunks_read += 1
        block.call(chunk)
      end
    end
    with_http_response(response) do
      assert_equal :unavailable, Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer").status
      assert_equal 2, chunks_read
    end
  end

  private

  def with_http_response(response)
    client_class = Class.new do
      attr_accessor :use_ssl, :verify_mode, :verify_hostname, :open_timeout, :read_timeout, :write_timeout, :max_retries
      attr_reader :requests

      def initialize(response)
        @response = response
        @requests = []
      end

      def start
        yield self
      end

      def request(request)
        @requests << request
        yield @response
      end
    end
    client = client_class.new(response)
    original_new = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*| client }
    yield client
  ensure
    Net::HTTP.define_singleton_method(:new, original_new) if original_new
  end
end
