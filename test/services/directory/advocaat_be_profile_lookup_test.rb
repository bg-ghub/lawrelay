require "test_helper"

class AdvocaatBeProfileLookupTest < ActiveSupport::TestCase
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

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

  test "rejects redirects rather than following a new endpoint" do
    result = Directory::AdvocaatBeProfileLookup.call(profile_url: PROFILE_URL, full_name: "Jane Lawyer", fetcher: ->(_) { nil })

    assert_equal :unavailable, result.status
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
end
