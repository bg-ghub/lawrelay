require "test_helper"

class DirectoryProfileImportTest < ActiveSupport::TestCase
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

  test "imports only supported professional profile fields from the main content" do
    result = lookup(profile_html)

    assert result.success?
    assert_equal({ spoken_languages: %w[NL EN FR], practice_areas: [ "Familierecht", "Handelsrecht" ] }, result.profile_attributes)
    assert_empty(result.profile_attributes.keys & %i[bar_number bar_association directory_email directory_profile_id professional_email])
    refute_respond_to result, :firm_attributes
  end

  test "keeps missing fields absent instead of returning blank overwrites" do
    result = lookup('<main id="main"><h1>Jane Lawyer</h1><div><h2>Talen</h2><p>Frans</p></div></main>')

    assert result.success?
    assert_equal({ spoken_languages: [ "FR" ] }, result.profile_attributes)
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
    result = lookup('<main id="main"><h1>Jane Lawyer</h1><h2>Contact</h2><address>Example Street 10<br>1000 Brussel</address><a href="tel:+3225550101">Phone</a></main>')

    assert_equal :empty, result.status
    assert_empty result.profile_attributes
  end

  private

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
