require "test_helper"

class DirectoryAdvocaatBeNameSearchTest < ActiveSupport::TestCase
  test "searches only the fixed official HTTPS endpoint with encoded partial Unicode names" do
    calls = []
    result = search("  Éléonore  O’Neil ", fetcher: ->(uri) { calls << uri; search_html(card(1, name: "Éléonore O’Neil")) })

    assert result.success?
    assert_equal "https", calls.sole.scheme
    assert_equal "www.advocaat.be", calls.sole.host
    assert_equal 443, calls.sole.port
    assert_equal "/nl/zoek-een-advocaat", calls.sole.path
    assert_nil calls.sole.userinfo
    assert_equal({ "theme" => "", "radius" => "", "name" => "Éléonore O’Neil", "languages" => "", "diplomas" => "" }, URI.decode_www_form(calls.sole.query).to_h)
    assert_equal [ { "name" => "Éléonore O’Neil", "profile_url" => profile_url(1), "location" => "1000 Brussel" } ], result.candidates
    assert_not result.truncated
    assert_equal %i[status candidates truncated], result.members
  end

  test "invalid or excessive search input cannot cause a remote request" do
    calls = []
    [ nil, [], {}, "", " a ", "Li", "...", "1ab", "x" * 101, "name@example.test", "https://evil.test", "<script>", "a\xFF".b.force_encoding("UTF-8") ].each do |query|
      result = search(query, fetcher: ->(uri) { calls << uri; search_html })
      assert_equal :invalid_query, result.status
      assert_empty result.candidates
    end
    assert_empty calls
    assert Directory::AdvocaatBeNameSearch.normalized_query("van den Berg")
    assert Directory::AdvocaatBeNameSearch.normalized_query("Ber")
    assert Directory::AdvocaatBeNameSearch.normalized_query("D'Hondt")
  end

  test "only result-card headings are parsed and duplicate canonical profiles are deduplicated" do
    html = search_html(card(1) + card(1, name: "Repeated result") + card(2, name: "Jan de Vries"))
    html += "<div class='card'><h3><a href='#{profile_url(3)}'>Outside main</a></h3></div>"
    html.sub!("</main>", "<h3><a href='#{profile_url(4)}'>Outside result card</a></h3></main>")
    result = search("Vries", fetcher: ->(_) { html })

    assert result.success?
    assert_equal [ profile_url(1), profile_url(2) ], result.candidates.pluck("profile_url")
    assert_equal %w[location name profile_url], result.candidates.first.keys.sort
    assert_not_includes result.candidates.to_json, "hidden-person@example.test"
    assert_not_includes result.candidates.to_json, "Example Street"
  end

  test "untrusted URL variants and empty or oversized names are rejected" do
    bad_urls = [ "//evil.test/profile", "https://evil.test/profile", profile_url(1).sub("https", "http"),
      "#{profile_url(1)}?redirect=https://evil.test", "#{profile_url(1)}#fragment",
      profile_url(1).sub("www.advocaat.be", "www.advocaat.be:444"),
      profile_url(1).sub("www.advocaat.be", "user@www.advocaat.be") ]
    cards = bad_urls.map { |href| card(1, href:) }.join + card(2, name: "") + card(3, name: "x" * 202) + card(5, name: "hidden-person@example.test") + card(4)
    result = search("Lawyer", fetcher: ->(_) { search_html(cards) })

    assert_equal [ profile_url(4) ], result.candidates.pluck("profile_url")
  end

  test "no results is a successful empty search and excessive results are capped" do
    empty = search("Absent", fetcher: ->(_) { search_html })
    assert empty.success?
    assert_empty empty.candidates
    assert_not empty.truncated

    many = search("Lawyer", fetcher: ->(_) { search_html((1..12).map { |number| card(number) }.join) })
    assert many.success?
    assert_equal 8, many.candidates.length
    assert many.truncated
  end

  test "empty oversized malformed and unavailable responses fail without upstream details" do
    [ nil, "", {}, "x" * (Directory::AdvocaatBeNameSearch::MAX_BODY_BYTES + 1), "<main id='main'><h1>Unavailable</h1></main>" ].each do |html|
      result = search("Lawyer", fetcher: ->(_) { html })
      assert_equal :unavailable, result.status
      assert_empty result.candidates
    end
    [ Net::ReadTimeout, Net::HTTPBadResponse, Timeout::Error ].each do |error_class|
      result = search("Lawyer", fetcher: ->(_) { raise error_class, "private upstream detail" })
      assert_equal :unavailable, result.status
      assert_not_includes result.to_json, "private upstream detail"
    end
  end

  test "only successful sanitized candidates are briefly cached under a hashed query key" do
    cache = ActiveSupport::Cache::MemoryStore.new
    writes = []
    original_write = cache.method(:write)
    cache.define_singleton_method(:write) do |key, value, **options|
      writes << [ key, value, options ]
      original_write.call(key, value, **options)
    end
    calls = 0
    fetcher = ->(_) { calls += 1; search_html(card(1)) }
    first = search("Jane Lawyer", fetcher:, cache:)
    first.candidates.first["name"] = "Client mutation"
    second = search("jane lawyer", fetcher:, cache:)
    assert_equal 1, calls
    assert_equal "Jane Lawyer", second.candidates.first.fetch("name")
    key, payload, options = writes.sole
    assert_match(/\Adirectory-name-search:v1:[a-f0-9]{64}\z/, key)
    assert_equal 10.minutes, options.fetch(:expires_in)
    assert_not_includes key.downcase, "jane"
    assert_not_includes payload.to_json, "hidden-person@example.test"
    assert_not_includes payload.to_json, "Example Street"

    travel 11.minutes do
      search("Jane Lawyer", fetcher:, cache:)
      assert_equal 2, calls
    end
  end

  test "failures are not cached and an invalid cached payload is not exposed" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    fetcher = ->(_) { calls += 1; calls == 1 ? nil : search_html(card(1)) }
    assert_equal :unavailable, search("Lawyer", fetcher:, cache:).status
    assert search("Lawyer", fetcher:, cache:).success?
    assert_equal 2, calls
    key = "directory-name-search:v1:#{Digest::SHA256.hexdigest('lawyer')}"
    cache.write(key, { "candidates" => [ { "name" => "Poisoned", "profile_url" => nil, "location" => nil } ], "truncated" => false })
    result = search("Lawyer", fetcher:, cache:)
    assert_equal 3, calls
    assert_equal [ profile_url(1) ], result.candidates.pluck("profile_url")
  end

  test "HTTPS transport rejects redirects without reading the body and disables proxies and retries" do
    response = Net::HTTPFound.new("1.1", "302", "Found")
    response["location"] = "https://unrelated.test"
    response.define_singleton_method(:read_body) { |&| raise "Must not read rejected body" }
    transport = fake_transport(response)
    arguments = nil
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*args| arguments = args; transport }
    result = Directory::AdvocaatBeNameSearch.call(name_query: "Lawyer", cache: nil)

    assert_equal :unavailable, result.status
    assert_equal [ "www.advocaat.be", 443, nil ], arguments
    assert transport.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, transport.verify_mode
    assert_equal 0, transport.max_retries
    assert_equal 5, transport.open_timeout
    assert_equal 8, transport.read_timeout
    assert_equal 5, transport.write_timeout
  ensure
    Net::HTTP.define_singleton_method(:new, original) if original
  end

  test "streamed HTTP bodies stop at the size limit" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/html"
    response.define_singleton_method(:read_body) do |&block|
      block.call("x" * Directory::AdvocaatBeNameSearch::MAX_BODY_BYTES)
      block.call("x")
      raise "Oversized body must be interrupted"
    end
    original = Net::HTTP.method(:new)
    transport = fake_transport(response)
    Net::HTTP.define_singleton_method(:new) { |*| transport }
    assert_equal :unavailable, Directory::AdvocaatBeNameSearch.call(name_query: "Lawyer", cache: nil).status
  ensure
    Net::HTTP.define_singleton_method(:new, original) if original
  end

  private

  def search(query, fetcher:, cache: nil)
    Directory::AdvocaatBeNameSearch.call(name_query: query, fetcher:, cache:)
  end

  def search_html(cards = "")
    "<main id='main'><form action='/nl/zoek-een-advocaat'><input name='name'></form>#{cards}</main>"
  end

  def card(number, name: "Jane Lawyer", href: profile_url(number))
    "<div class='card bg-primary'><h3><a href='#{href}'>#{name}</a></h3><address>Example Street 10,<br>1000 Brussel</address><div class='hidden print:block'>hidden-person@example.test</div><a href='#{href}'>More details</a></div>"
  end

  def profile_url(number)
    "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{format('00000000-0000-4000-8000-%012d', number)}"
  end

  def fake_transport(response)
    Class.new do
      attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries

      define_method(:start) { |&block| block.call(self) }
      define_method(:request) { |_request, &block| block.call(response) }
    end.new
  end
end
