require "test_helper"

class DirectorySignupProfileTest < ActiveSupport::TestCase
  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111"

  test "previews only the name email and supported professional preferences" do
    calls = []
    result = Directory::SignupProfile.call(profile_url: PROFILE_URL.sub("www.", ""), fetcher: ->(uri) { calls << uri.to_s; profile_html })

    assert result.success?
    assert_equal [ PROFILE_URL ], calls
    assert_equal "Jane van den Berg", result.name
    assert_equal "Jane", result.first_name
    assert_equal "van den Berg", result.last_name
    assert_equal "listed@example.test", result.email_address
    assert_equal({ spoken_languages: %w[NL EN FR], practice_areas: %w[Familierecht Handelsrecht] }, result.profile_attributes)
    assert_equal %i[status profile_url name first_name last_name email_address profile_attributes], result.members
    assert_empty(result.profile_attributes.keys & %i[name address_line_1 postal_code city phone iban bar_number verification_status directory_email_verified_at])
  end

  test "invalid URLs cannot cause an outbound request" do
    calls = []
    fetcher = ->(uri) { calls << uri; profile_html }
    [ nil, "https://evil.example/profile", PROFILE_URL.sub("https", "http"),
      "#{PROFILE_URL}?redirect=https://evil.example", "#{PROFILE_URL}#fragment",
      PROFILE_URL.sub("www.advocaat.be", "www.advocaat.be:444"),
      PROFILE_URL.sub("www.advocaat.be", "user@www.advocaat.be") ].each do |url|
      assert_equal :invalid_url, Directory::SignupProfile.call(profile_url: url, fetcher:).status
    end
    assert_empty calls
  end

  test "a page without a valid main heading or listed email is not imported" do
    assert_equal :malformed, lookup('<h1>Outside name</h1><a href="mailto:outside@example.test">Email</a>').status
    assert_equal :malformed, lookup('<main id="main"><h1></h1></main>').status
    assert_equal :malformed, lookup("<main id='main'><h1>#{'x' * 202}</h1></main>").status
    assert_equal :email_missing, lookup('<main id="main"><h1>Jane Lawyer</h1><a href="mailto:invalid">Email</a></main>').status
  end

  test "missing optional preferences do not prevent a basic identity preview" do
    result = lookup('<main id="main"><h1>Jane Lawyer</h1><a href="mailto:listed@example.test">Email</a></main>')
    assert result.success?
    assert_empty result.profile_attributes
  end

  test "unusual given and family names stay editable without truncated identity evidence" do
    result = lookup(profile_html.sub("Jane van den Berg", "SingleName"))
    assert result.success?
    assert_equal "SingleName", result.name
    assert_equal "SingleName", result.first_name
    assert_equal "", result.last_name

    result = lookup(profile_html.sub("Jane van den Berg", "#{'a' * 101} Family"))
    assert result.success?
    assert_equal "", result.first_name
    assert_equal "Family", result.last_name
  end

  test "empty oversized and unavailable responses do not expose remote details" do
    [ nil, "", "x" * (Directory::SignupProfile::MAX_BODY_BYTES + 1) ].each do |body|
      result = lookup(body)
      assert_equal :unavailable, result.status
      assert_nil result.email_address
      assert_empty result.profile_attributes
    end
    result = Directory::SignupProfile.call(profile_url: PROFILE_URL, fetcher: ->(_) { raise Net::ReadTimeout, "private upstream details" })
    assert_equal :unavailable, result.status
    assert_nil result.name
  end

  test "the HTTPS transport never follows or reads a rejected response body" do
    response = Net::HTTPFound.new("1.1", "302", "Found")
    response["location"] = "https://unrelated.example/profile"
    response.define_singleton_method(:read_body) { |&| raise "A rejected response body must not be read" }
    transport = fake_transport(response)
    with_transport(transport) do
      assert_equal :unavailable, Directory::SignupProfile.call(profile_url: PROFILE_URL).status
    end
    assert transport.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, transport.verify_mode
    assert_equal 0, transport.max_retries
    assert_equal 5, transport.open_timeout
    assert_equal 8, transport.read_timeout
  end

  test "streamed HTML is stopped at the size limit" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/html"
    response.define_singleton_method(:read_body) do |&block|
      block.call("x" * Directory::SignupProfile::MAX_BODY_BYTES)
      block.call("x")
      raise "The oversized response must have been interrupted"
    end
    with_transport(fake_transport(response)) do
      assert_equal :unavailable, Directory::SignupProfile.call(profile_url: PROFILE_URL).status
    end
  end

  private

  def fake_transport(response)
    Class.new do
      attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :max_retries

      define_method(:start) { |&block| block.call(self) }
      define_method(:request) { |_request, &block| block.call(response) }
    end.new
  end

  def with_transport(transport)
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*| transport }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original) if original
  end

  def lookup(html)
    Directory::SignupProfile.call(profile_url: PROFILE_URL, fetcher: ->(_) { html })
  end

  def profile_html
    <<~HTML
      <h1>Outside name</h1><a href="mailto:outside@example.test">Outside email</a>
      <main id="main"><h1>Jane van den Berg</h1>
        <div><h2>Talen</h2><p>Nederlands, Engels, Frans</p></div>
        <div><h2>Voorkeurmateries</h2><p>Familierecht, Handelsrecht</p></div>
        <h2>Balies</h2><p>Unverified public bar details</p>
        <h2>Derdenrekening</h2><p>Excluded bank details</p>
        <h2>Contact</h2><address>Do not use as billing address<br>1000 Brussels</address>
        <a href="mailto:LISTED@example.test?subject=Contact">Email</a><a href="tel:+3225550101">Phone</a>
      </main>
    HTML
  end
end
