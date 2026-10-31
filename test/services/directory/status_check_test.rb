require "minitest/autorun"
require "active_support"
require "active_support/core_ext"
require_relative "../../../app/services/directory/advocaat_be_profile_lookup"
require_relative "../../../app/services/directory/status_check"

class DirectoryStatusCheckTest < Minitest::Test
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

  class HttpClient
    attr_accessor :use_ssl, :verify_mode, :verify_hostname, :open_timeout,
      :read_timeout, :write_timeout, :max_retries
    attr_reader :requests, :closed, :autodrain_attempted

    def initialize(response)
      @response = response
      @requests = []
    end

    def start
      yield self
    ensure
      @closed = true
    end

    def request(request)
      @requests << request
      yield @response
      @autodrain_attempted = true
      raise "Net::HTTP would automatically drain the rejected body"
    end
  end

  def test_active_profile_uses_the_existing_full_name_normalization
    result = check(body: html(name: "Jàne-Lawyer"), expected_email: " JANE@example.test ")

    assert_equal :active, result.status
    assert_equal [ :status, :checked_at ], result.members
    assert_kind_of Time, result.checked_at
  end

  def test_expected_email_is_optional_but_a_valid_listed_email_is_required
    assert_equal :active, check.status
    assert_equal :unavailable, check(body: html(email: "")).status
    assert_equal :unavailable, check(body: html(email: "invalid")).status
    assert_equal :unavailable, check(expected_email: "invalid").status
  end

  def test_a_real_profile_name_or_expected_email_change_is_changed
    assert_equal :changed, check(body: html(name: "Another Lawyer")).status
    assert_equal :changed, check(expected_email: "old@example.test").status
    assert_equal :active, check(body: html(email: "JANE@example.test?subject=Question"), expected_email: "jane@example.test").status
  end

  def test_only_explicit_404_or_410_proves_a_profile_is_not_listed
    [ 404, "404", 410, "410" ].each do |status|
      result = check(status:, body: nil)
      assert_equal :not_listed, result.status
      assert_kind_of Time, result.checked_at
    end

    [ 301, 302, 307, 308, 403, 429, 500, 502, 503, "404 invalid", nil ].each do |status|
      assert_equal :unavailable, check(status:).status
    end
  end

  def test_directory_text_does_not_prove_inactivity_or_removal
    assert_equal :active, check(body: html + "<p>inactive, removed, not found, stopgezet</p>").status
    assert_equal :unavailable, check(body: "<h1>404 Not Found</h1>").status
  end

  def test_cookie_headings_and_contact_details_outside_main_cannot_verify_a_profile
    assert_equal :active, check(body: "<h1>Cookie settings</h1>#{html}").status
    assert_equal :unavailable, check(body: '<main id="main"><h1>Jane Lawyer</h1></main><a href="mailto:jane@example.test">Email</a>').status
    assert_equal :unavailable, check(body: '<h1>Jane Lawyer</h1><main id="main"><a href="mailto:jane@example.test">Email</a></main>').status
  end

  def test_missing_or_ambiguous_profile_layout_stays_unavailable
    [ "", " ", "<html><p>Outage</p></html>", html.sub('id="main"', 'id="other"'),
      html.sub("<h1>Jane Lawyer</h1>", "<h1></h1>"), html + html,
      html.sub("</h1>", "</h1><h1>Another heading</h1>"), html(name: "Different", email: "") ].each do |body|
      assert_equal :unavailable, check(body:).status
    end
  end

  def test_invalid_or_external_urls_never_reach_the_transport
    urls = [ "http://#{URI(PROFILE_URL).host}#{URI(PROFILE_URL).path}",
      PROFILE_URL.sub("www.advocaat.be", "127.0.0.1"),
      PROFILE_URL.sub("www.advocaat.be", "www.advocaat.be.evil.example"),
      PROFILE_URL.sub("www.advocaat.be", "user@www.advocaat.be"),
      PROFILE_URL.sub("www.advocaat.be", "www.advocaat.be:444"),
      "#{PROFILE_URL}/", "#{PROFILE_URL}?next=https://evil.example", "#{PROFILE_URL}#fragment",
      "#{PROFILE_URL}?", "#{PROFILE_URL}#", "not a URI" ]
    transport = ->(*) { flunk "An invalid URL must never be requested" }

    urls.each do |profile_url|
      assert_equal :unavailable, Directory::StatusCheck.call(profile_url:, full_name: "Jane Lawyer", transport:).status
    end
  end

  def test_transport_receives_only_the_exact_canonical_profile_request
    calls = []
    transport = lambda do |uri, request|
      calls << [ uri, request ]
      [ 404, nil ]
    end

    result = Directory::StatusCheck.call(profile_url: PROFILE_URL.sub("www.", ""), full_name: "Jane Lawyer", transport:)

    assert_equal :not_listed, result.status
    assert_equal 1, calls.size
    assert_equal PROFILE_URL, calls.first.first.to_s
    assert_equal URI(PROFILE_URL).request_uri, calls.first.last.path
    assert_kind_of Net::HTTP::Get, calls.first.last
  end

  def test_network_and_protocol_failures_are_unavailable
    [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error,
      SocketError, IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError ].each do |error|
      transport = ->(*) { raise error, "private upstream details" }
      result = Directory::StatusCheck.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", transport:)

      assert_equal :unavailable, result.status
      assert_equal [ :status, :checked_at ], result.members
    end
  end

  def test_the_total_timeout_wraps_the_transport_and_parser
    original_timeout = Timeout.method(:timeout)
    durations = []
    Timeout.define_singleton_method(:timeout) do |seconds, &block|
      durations << seconds
      block.call
    end

    assert_equal :active, check.status
    assert_equal [ 15 ], durations
  ensure
    Timeout.define_singleton_method(:timeout, original_timeout) if original_timeout
  end

  def test_injected_transport_results_are_bounded_and_need_a_string_body
    [ nil, {}, false, 123 ].each do |body|
      assert_equal :unavailable, check(body:).status
    end
    body = html + " " * (Directory::StatusCheck::MAX_BODY_BYTES - html.bytesize)

    assert_equal :active, check(body:).status
    assert_equal :unavailable, check(body: body + " ").status
  end

  def test_entity_declarations_are_not_parsed
    body = '<!DOCTYPE html [<!ENTITY contact SYSTEM "file:///private">]>' + html

    assert_equal :unavailable, check(body:).status
  end

  def test_http_requests_keep_peer_verification_timeout_bounds_and_zero_retries
    with_http_response(http_response) do |client, endpoint|
      assert_equal :active, live_transport_check.status
      assert_equal [ "www.advocaat.be", 443 ], endpoint
      assert client.use_ssl
      assert_equal OpenSSL::SSL::VERIFY_PEER, client.verify_mode
      assert client.verify_hostname
      assert_equal 5, client.open_timeout
      assert_equal 8, client.read_timeout
      assert_equal 5, client.write_timeout
      assert_equal 0, client.max_retries
      assert_equal URI(PROFILE_URL).request_uri, client.requests.first.path
      assert client.closed
    end
  end

  def test_http_missing_profiles_do_not_read_or_autodrain_response_bodies
    %w[404 410].each do |code|
      response = http_response(code:)
      response.define_singleton_method(:read_body) { |&_| flunk "Do not read a missing profile body" }

      with_http_response(response) do |client|
        assert_equal :not_listed, live_transport_check.status
        assert_equal 1, client.requests.size
        refute client.autodrain_attempted
        assert client.closed
      end
    end
  end

  def test_http_redirects_and_provider_outages_are_neither_followed_nor_drained
    %w[301 302 307 308 403 429 500 503].each do |code|
      response = http_response(code:)
      response["Location"] = "http://127.0.0.1/private"
      response.define_singleton_method(:read_body) { |&_| flunk "Do not read a rejected response body" }

      with_http_response(response) do |client|
        assert_equal :unavailable, live_transport_check.status
        assert_equal 1, client.requests.size
        refute client.autodrain_attempted
        assert client.closed
      end
    end
  end

  def test_http_non_html_responses_are_rejected_without_a_body_read
    [ nil, "application/json", "text/html-fake" ].each do |content_type|
      response = http_response(content_type:)
      response.define_singleton_method(:read_body) { |&_| flunk "Do not read non-HTML bodies" }

      with_http_response(response) do |client|
        assert_equal :unavailable, live_transport_check.status
        refute client.autodrain_attempted
      end
    end
  end

  def test_http_oversize_headers_are_rejected_without_reading_the_body
    response = http_response
    response["Content-Length"] = (Directory::StatusCheck::MAX_BODY_BYTES + 1).to_s
    response.define_singleton_method(:read_body) { |&_| flunk "Do not read a known oversize body" }

    with_http_response(response) do |client|
      assert_equal :unavailable, live_transport_check.status
      assert client.closed
      refute client.autodrain_attempted
    end
  end

  def test_streamed_body_overflow_aborts_immediately_without_autodrain
    response = http_response
    reads = 0
    chunks = [ "a" * Directory::StatusCheck::MAX_BODY_BYTES, "overflow", "do not read" ]
    response.define_singleton_method(:read_body) do |&block|
      chunks.each do |chunk|
        reads += 1
        block.call(chunk)
      end
    end

    with_http_response(response) do |client|
      assert_equal :unavailable, live_transport_check.status
      assert_equal 2, reads
      assert client.closed
      refute client.autodrain_attempted
    end
  end

  private

  def html(name: "Jane Lawyer", email: "jane@example.test")
    %(<html><body><main id="main"><h1>#{name}</h1><a href="mailto:#{email}">Email</a></main></body></html>)
  end

  def check(status: 200, body: html, expected_email: nil)
    Directory::StatusCheck.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", expected_email:,
      transport: ->(*) { [ status, body ] })
  end

  def live_transport_check
    Directory::StatusCheck.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer")
  end

  def http_response(code: "200", content_type: "text/html; charset=utf-8")
    response = Net::HTTPResponse.new("1.1", code, "Response")
    response["Content-Type"] = content_type if content_type
    body = html
    response.define_singleton_method(:read_body) { |&block| block.call(body) }
    response
  end

  def with_http_response(response)
    client = HttpClient.new(response)
    endpoint = []
    original_new = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) do |host, port|
      endpoint.replace([ host, port ])
      client
    end
    yield client, endpoint
  ensure
    Net::HTTP.define_singleton_method(:new, original_new) if original_new
  end
end
