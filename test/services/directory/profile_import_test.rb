require "test_helper"

class DirectoryProfileImportTest < ActiveSupport::TestCase
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
  MOVED_URL = PROFILE_URL.sub("63fee2a5", "73fee2a5")

  test "imports only supported professional profile fields from the main content" do
    result = lookup(profile_html)

    assert result.success?
    assert_equal({ spoken_languages: %w[NL EN FR], practice_areas: [ "Familierecht", "Handelsrecht" ],
      directory_bar_name: "Do not change bar evidence", directory_professional_address: "Example Street 10 , 1000 Brussel" }, result.profile_attributes)
    assert_empty(result.profile_attributes.keys & %i[bar_number bar_association directory_email directory_profile_id professional_email])
    refute_respond_to result, :firm_attributes
  end

  test "keeps missing fields absent instead of returning blank overwrites" do
    result = lookup('<main id="main"><h1>Jane Lawyer</h1><div><h2>Talen</h2><p>Frans</p></div></main>')

    assert result.success?
    assert_equal({ spoken_languages: [ "FR" ], directory_bar_name: nil, directory_professional_address: nil }, result.profile_attributes)
  end

  test "only requests the canonical official stored-profile URL" do
    calls = []
    fetcher = ->(uri) { calls << uri.to_s; profile_html }
    [ "https://evil.example/profile", "#{PROFILE_URL}?next=https://evil.example", PROFILE_URL.sub("https", "http"),
      PROFILE_URL.sub("www.advocaat.be", "www.advocaat.be:444") ].each do |url|
      result = Directory::ProfileImport.call(profile_url: url, full_name: "Jane Lawyer", fetcher: fetcher)
      assert_equal :missing_profile, result.status
    end
    assert_empty calls

    assert Directory::ProfileImport.call(profile_url: PROFILE_URL.sub("www.", ""), full_name: "Jane Lawyer", fetcher: fetcher).success?
    assert_equal [ PROFILE_URL ], calls
  end

  test "rejects a different identity and ignores unrelated document content" do
    result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Someone Else", fetcher: ->(_) { profile_html })
    assert_equal :identity_mismatch, result.status
    assert_empty result.profile_attributes

    result = lookup("<h1>Jane Lawyer</h1><h2>Talen</h2><p>Nederlands</p>")
    assert_equal :unavailable, result.status
  end

  test "matched profiles require the stored name and published directory email on direct and moved pages" do
    [ nil, "301", "308" ].each do |code|
      [ [ "Jane Lawyer", "LISTED@example.test", :ok ], [ "Other Lawyer", "listed@example.test", :identity_mismatch ],
        [ "Jane Lawyer", "different@example.test", :identity_mismatch ] ].each do |name, email, expected_status|
        requests = []
        fetcher = lambda do |uri|
          requests << uri.to_s
          code && uri.to_s == PROFILE_URL ? redirect(code, URI(MOVED_URL).path) : profile_html
        end
        result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: name, expected_email: email, fetcher:)

        assert_equal expected_status, result.status
        assert_equal(code ? [ PROFILE_URL, MOVED_URL ] : [ PROFILE_URL ], requests)
        if result.success? && code
          assert_equal MOVED_URL.split("/").last, result.redirected_profile_id
        else
          assert_nil result.redirected_profile_id
        end
        assert_empty result.profile_attributes unless result.success?
      end
    end
    html = profile_html.sub("mailto:listed@example.test", "tel:123")
    result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer",
      expected_email: "listed@example.test", fetcher: ->(_) { html })
    assert_equal :identity_mismatch, result.status
    assert_empty result.profile_attributes
  end

  test "a redirect requires a stored email and exactly one permanent official profile destination" do
    cases = [
      [ "301", MOVED_URL, nil ], [ "302", MOVED_URL, "listed@example.test" ],
      [ "307", MOVED_URL, "listed@example.test" ], [ "301", PROFILE_URL, "listed@example.test" ],
      [ "308", MOVED_URL.sub("https:", "http:"), "listed@example.test" ],
      [ "301", MOVED_URL.sub("www.advocaat.be", "example.test"), "listed@example.test" ],
      [ "301", MOVED_URL.sub("www.advocaat.be", "name@www.advocaat.be"), "listed@example.test" ],
      [ "308", MOVED_URL.sub("www.advocaat.be", "www.advocaat.be:444"), "listed@example.test" ],
      [ "301", "#{MOVED_URL}?page=1", "listed@example.test" ], [ "308", "#{MOVED_URL}#profile", "listed@example.test" ],
      [ "301", "/nl/zoek-een-advocaat", "listed@example.test" ], [ "308", "mailto:invalid", "listed@example.test" ],
      [ "301", "https://[", "listed@example.test" ]
    ]
    cases.each do |code, location, expected_email|
      requests = []
      fetcher = ->(uri) { requests << uri.to_s; redirect(code, location) }
      result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", expected_email:, fetcher:)
      assert_not result.success?
      assert_equal [ PROFILE_URL ], requests
    end

    requests = []
    fetcher = ->(uri) { requests << uri.to_s; redirect("301", MOVED_URL) }
    result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", expected_email: "listed@example.test", fetcher:)
    assert_not result.success?
    assert_equal [ PROFILE_URL, MOVED_URL ], requests
  end

  test "empty malformed oversized and unavailable responses fail without details" do
    [ nil, "", '<main id="main"><h1>Jane Lawyer</h1></main>', "x" * (Directory::ProfileImport::MAX_BODY_BYTES + 1) ].each do |body|
      result = lookup(body)
      assert_not result.success?
      assert_empty result.profile_attributes
    end
    result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher: ->(_) { raise Net::ReadTimeout })
    assert_equal :unavailable, result.status
  end

  test "returns empty when a valid profile has no supported professional fields" do
    result = lookup('<main id="main"><h1>Jane Lawyer</h1><h2>Contact</h2><p>No structured address</p><a href="tel:+3225550101">Phone</a></main>')

    assert_equal :empty, result.status
    assert_empty result.profile_attributes
  end

  test "imports only structured address and bar content within the main profile" do
    html = <<~HTML
      <main id="main"><h1>Jane Lawyer</h1>
        <h2>Balies</h2><p>Balie Brussel Nederlandse Orde</p>
        <h2>Contact</h2><address>Zavelstraat 13<br>1000 Brussel</address>
        <div data-address="ignore">Injected text</div>
        <h2>Derdenrekening</h2><p>BE00 0000 0000 0000</p>
      </main>
    HTML

    result = lookup(html)

    assert_equal "Balie Brussel Nederlandse Orde", result.profile_attributes[:directory_bar_name]
    assert_equal "Zavelstraat 13 1000 Brussel", result.profile_attributes[:directory_professional_address]
    assert_not_includes result.profile_attributes[:directory_professional_address], "Injected"
    assert_not_includes result.profile_attributes[:directory_professional_address], "BE00"
  end

  test "a total request timeout fails without retaining provider details" do
    result = Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer",
      fetcher: ->(_) { raise Timeout::Error, "Private provider transport detail" })

    assert_equal :unavailable, result.status
    assert_empty result.profile_attributes
  end

  test "provider fetches run inside the bounded total timeout" do
    budgets = []
    original = Timeout.method(:timeout)
    Timeout.define_singleton_method(:timeout) do |seconds, &block|
      budgets << seconds
      block.call
    end

    assert lookup(profile_html).success?
    assert_equal [ 15 ], budgets
  ensure
    Timeout.define_singleton_method(:timeout, original) if original
  end

  private

  def redirect(code, location)
    Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "Redirect").tap { |response| response["location"] = location }
  end

  def lookup(html)
    Directory::ProfileImport.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher: ->(_) { html })
  end

  def profile_html
    <<~HTML
      <h1>Outside content</h1><a href="tel:+3211111111">Unrelated number</a>
      <main id="main"><h1>Jane Lawyer</h1>
        <div><h2>Talen</h2><p>Nederlands, Engels, Frans</p></div>
        <div><h2>Voorkeurmateries</h2><p>Familierecht, Handelsrecht</p></div>
        <div><h2>Balies</h2><p>Do not change bar evidence</p></div>
        <div><h2>Derdenrekening</h2><p>Do not import bank details</p></div>
        <div><h2>Contact</h2><address>Example Street 10 ,<br>1000 Brussel</address>
          <a href="mailto:listed@example.test">Listed email is not imported</a><a href="tel:+3225550101">Phone</a>
        </div>
      </main>
    HTML
  end
end
