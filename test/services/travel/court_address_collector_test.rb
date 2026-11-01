require "test_helper"
require_relative "../../../script/ops/collect-court-addresses"

class CourtAddressCollectorTest < ActiveSupport::TestCase
  SOURCE = "https://www.tribunaux-rechtbanken.be/nl/vredegerecht-anderlecht-1e-kanton"

  test "extracts a single structured court address without map or contact links" do
    result = CourtAddressCollector.parse(page(<<~HTML))
      <div class="paragraph--type--address"><ul>
        <li>Verzetsplein 3<br>1070 Anderlecht</li>
        <li><a href="https://maps.example.test">View Google Maps</a></li>
        <li><a href="mailto:someone@example.test">Contact the clerk</a></li>
      </ul></div>
    HTML
    assert_equal "ok", result[:status]
    assert_equal "Test court", result[:title]
    assert_equal [ "Verzetsplein 3 1070 Anderlecht" ], result[:addresses]
  end

  test "multiple buildings remain ambiguous rather than choosing a building" do
    result = CourtAddressCollector.parse(page(<<~HTML))
      <div class="paragraph--type--address"><ul>
        <li>Example Square 1<br>1000 Brussel</li>
        <li>Other Street 2<br>2000 Antwerpen</li>
      </ul></div>
    HTML
    assert_equal "ambiguous", result[:status]
    assert_equal 2, result[:addresses].size
  end

  test "structured civic addresses need not have a house number but postal boxes are excluded" do
    result = CourtAddressCollector.parse(page(<<~HTML))
      <div class="paragraph--type--address"><ul>
        <li>Place de l'Hôtel de Ville<br>1300 Wavre</li>
        <li>Boîte postale 10<br>1000 Bruxelles</li>
      </ul></div>
    HTML
    assert_equal "ok", result[:status]
    assert_equal [ "Place de l'Hôtel de Ville 1300 Wavre" ], result[:addresses]
  end

  test "supports court headings outside main and nonbreaking address spaces" do
    result = CourtAddressCollector.parse(<<~HTML)
      <h1>Official court title</h1><main><address>Example&nbsp;Street 10<br>1000&nbsp;Brussel</address></main>
    HTML
    assert_equal "Official court title", result[:title]
    assert_equal [ "Example Street 10 1000 Brussel" ], result[:addresses]
  end

  test "court contact markup yields only the street and following postal city line" do
    result = CourtAddressCollector.parse(page(<<~HTML))
      <div id="list-contact"><div class="paragraph--type--remark-html"><p>
        Gerechtsgebouw Hasselt<br>Parklaan 25 bus 4<br>3500 Hasselt<br>1e verdieping<br>
        Phone 011 00 00 00<br>IBAN BE00 0000 0000 0000<br>
        <a href="https://maps.example.test">Google Maps</a><a href="mailto:clerk@example.test">Email</a>
      </p></div></div>
      <div class="paragraph--type--remark-html"><p>Unrelated Street 5<br>3000 Leuven</p></div>
    HTML
    assert_equal "ok", result[:status]
    assert_equal [ "Parklaan 25 bus 4 3500 Hasselt" ], result[:addresses]
  end

  test "different court contact locations remain ambiguous and floor lines are not street addresses" do
    result = CourtAddressCollector.parse(page(<<~HTML))
      <div id="list-contact"><div class="paragraph--type--remark-html">
        <p>Example Street 1<br>1000 Brussel<br>2e verdieping</p>
        <p>Other Street 2<br>2000 Antwerpen</p>
        <p>1e verdieping<br>3000 Leuven</p>
      </div></div>
    HTML
    assert_equal "ambiguous", result[:status]
    assert_equal [ "Example Street 1 1000 Brussel", "Other Street 2 2000 Antwerpen" ], result[:addresses]
  end

  test "contact pass uses only an actual court-specific Contact link" do
    html = <<~HTML
      <nav><a href="/nl/contact">Contact</a>
        <a href="/nl/vredegerecht-anderlecht-1e-kanton/contact">Contact</a></nav>
      <a href="https://evil.example/contact">Contact</a>
    HTML
    assert_equal "#{SOURCE}/contact", CourtAddressCollector.contact_link(html, source_url: SOURCE)
    assert_nil CourtAddressCollector.contact_link('<a href="/nl/contact">Contact</a>', source_url: SOURCE)
    assert_nil CourtAddressCollector.contact_link("<main>No Contact link</main>", source_url: SOURCE)
  end

  test "central registry addresses in another city are not treated as the hearing venue" do
    assert CourtAddressCollector.address_matches_city?("Place Poelaert 1 1000 Bruxelles",
      city_names: %w[Brussel Bruxelles Brussels Brüssel])
    assert CourtAddressCollector.address_matches_city?("Kielenstraat 22/3 3700 Tongeren-Borgloon",
      city_names: [ "Tongeren-Borgloon", "Tongres-Looz" ])
    refute CourtAddressCollector.address_matches_city?("Kielenstraat 22 3700 Tongeren-Borgloon", city_names: [ "Genk" ])
    refute CourtAddressCollector.address_matches_city?("Parklaan 25 bus 4 3500 Hasselt", city_names: [ "Sint-Truiden" ])
  end

  test "ignores unrelated footer addresses arbitrary paragraphs and incomplete addresses" do
    result = CourtAddressCollector.parse(<<~HTML)
      <main><h1>Test court</h1><p>Wrong Street 5, 3000 Leuven</p>
        <div class="paragraph--type--address"><ul><li>1000 Brussel</li></ul></div>
        <footer><address>Footer Street 4, 1000 Brussel</address></footer>
      </main><footer><address>Other Footer 5, 1000 Brussel</address></footer>
    HTML
    assert_equal "not_found", result[:status]
    assert_empty result[:addresses]
  end

  test "deduplicates repeated address markup and supports semantic address elements" do
    result = CourtAddressCollector.parse(page(<<~HTML))
      <div class="paragraph--type--address"><address>Example Street 10<br>1000 Brussel</address></div>
      <address>Example Street 10, 1000 Brussel</address>
    HTML
    assert_equal "ok", result[:status]
    assert_equal [ "Example Street 10 1000 Brussel" ], result[:addresses]
  end

  test "rejects unapproved URLs before performing a request" do
    urls = [ "http://www.tribunaux-rechtbanken.be/nl/court", "https://evil.example/court",
      "https://www.tribunaux-rechtbanken.be:444/nl/court", "https://user@www.tribunaux-rechtbanken.be/nl/court",
      "https://www.tribunaux-rechtbanken.be/nl/court#fragment", "https://fr.const-court.be/other",
      "https://www.raadvst-consetat.be/?lang=nl&page=other" ]
    calls = []
    collector = CourtAddressCollector.new(sources: urls, transport: ->(uri) { calls << uri })
    urls.each { |url| assert_equal "unsafe_url", collector.collect(url)[:status] }
    assert_equal "unsafe_url", collector.collect("#{SOURCE}/not-in-catalogue")[:status]
    assert_empty calls
  end

  test "redirects stay on approved HTTPS sources and stop after two hops" do
    calls = []
    responses = [ response(302, location: "/nl/new-court"), response(200, body: page("<address>Example Street 10<br>1000 Brussel</address>")) ]
    result = collector(calls:, responses:).collect(SOURCE)
    assert_equal "ok", result[:status]
    assert_equal "https://www.tribunaux-rechtbanken.be/nl/new-court", result[:final_url]
    assert_equal 2, calls.size

    calls = []
    result = collector(calls:, responses: [ response(302, location: "https://evil.example/") ]).collect(SOURCE)
    assert_equal "unsafe_redirect", result[:status]
    assert_equal 1, calls.size

    calls = []
    responses = 3.times.map { |index| response(302, location: "/nl/hop-#{index}") }
    assert_equal "too_many_redirects", collector(calls:, responses:).collect(SOURCE)[:status]
    assert_equal 3, calls.size
  end

  test "request budget and pacing apply to redirects too" do
    now = 0.0
    waits = []
    calls = []
    transport = ->(uri) { calls << uri; response(200, body: page("")) }
    collector = CourtAddressCollector.new(sources: [ SOURCE ], transport:, clock: -> { now },
      sleeper: ->(seconds) { waits << seconds; now += seconds })
    (CourtAddressCollector::MAX_REQUESTS + 1).times { collector.collect(SOURCE) }
    assert_equal CourtAddressCollector::MAX_REQUESTS, calls.size
    assert_equal CourtAddressCollector::MAX_REQUESTS - 1, waits.size
    assert waits.all? { |wait| wait == 1.0 }
    assert_equal "request_limit", collector.collect(SOURCE)[:status]
  end

  test "a second-pass budget cannot exceed twenty network requests" do
    calls = []
    collector = CourtAddressCollector.new(sources: [ SOURCE ], request_limit: 20,
      transport: ->(uri) { calls << uri; response(200, body: page("")) }, clock: -> { 0 }, sleeper: ->(_) { })
    20.times { collector.collect(SOURCE) }
    assert_equal "request_limit", collector.collect(SOURCE)[:status]
    assert_equal 20, calls.size
  end

  test "generic homepage contact and category redirects are not assigned to a court" do
    [ "/", "/nl", "/fr/contact", "/nl/rechtbanken/politierechtbank" ].each do |destination|
      calls = []
      result = collector(calls:, responses: [ response(302, location: destination) ]).collect(SOURCE)
      assert_equal "generic_redirect", result[:status]
      assert_equal URI.join(SOURCE, destination).to_s, result[:final_url]
      assert_empty result[:addresses]
      assert_equal 1, calls.size
    end
  end

  test "oversized bodies and non-HTML responses return bounded failure records" do
    result = collector(responses: [ response(200, body: "x" * (CourtAddressCollector::MAX_BODY_BYTES + 1)) ]).collect(SOURCE)
    assert_equal "body_too_large", result[:status]
    assert_empty result[:addresses]

    result = collector(responses: [ response(200, body: "{}", content_type: "application/json") ]).collect(SOURCE)
    assert_equal "unsupported_content", result[:status]
    assert_empty result[:addresses]
  end

  private

  def page(content)
    "<main><h1>Test court</h1>#{content}</main>"
  end

  def response(status, body: "", location: nil, content_type: "text/html; charset=utf-8")
    CourtAddressCollector::Response.new(status:, body:, location:, content_type:)
  end

  def collector(calls: [], responses:)
    CourtAddressCollector.new(sources: [ SOURCE ],
      transport: ->(uri) { calls << uri.to_s; responses.shift }, clock: -> { 0 }, sleeper: ->(_) { })
  end
end
