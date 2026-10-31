require "test_helper"

class BusinessRegistryPublicLookupTest < ActiveSupport::TestCase
  test "reads only the active entity and its registered office from the public page" do
    result = lookup

    assert_predicate result, :success?
    assert_equal Date.new(2026, 10, 29), result.snapshot_date
    assert_equal({
      name: "TEST CBE Company",
      enterprise_number: "1234567894",
      address_line_1: "TEST Registerstraat 12 / 3",
      postal_code: "1000",
      city: "Brussel"
    }, result.attributes)
  end

  test "uses one fixed Dutch public-search GET request" do
    request_uri = request = nil
    result = BusinessRegistry::PublicLookup.call(enterprise_number: "BE 1234.567.894", locale: :fr,
      transport: ->(uri, built_request) { request_uri = uri; request = built_request; [ 200, fixture_html ] })

    assert_predicate result, :success?
    assert_equal "https", request_uri.scheme
    assert_equal "kbopub.economie.fgov.be", request_uri.host
    assert_equal "/kbopub/toonondernemingps.html", request_uri.path
    assert_equal({ "ondernemingsnummer" => "1234567894", "lang" => "nl" }, URI.decode_www_form(request_uri.query).to_h)
    assert_equal "GET", request.method
  end

  test "prefixes the registered legal form separately from the official name" do
    html = with_registry_rows(
      '<tr><td class="QL">Type entiteit:</td><td class="QL">Rechtspersoon</td></tr>',
      '<tr><td class="RL">Rechtsvorm:</td><td class="RL">Besloten Vennootschap<span class="upd"><br>Sinds 29 oktober 2026</span></td></tr>'
    ).sub("TEST CBE Company", "BG Legal")
    result = lookup(html:)

    assert_predicate result, :success?
    assert_equal "BV BG Legal", result.attributes[:name]
    assert_equal "TEST Registerstraat 12 / 3", result.attributes[:address_line_1]
    assert_equal Date.new(2026, 10, 29), result.snapshot_date
  end

  test "normalizes a legal form already present in the official name" do
    html = with_registry_rows('<tr><td class="RL">Rechtsvorm:</td><td class="RL">Besloten vennootschap</td></tr>')
      .sub("TEST CBE Company", "BG Legal (B.V.)")

    assert_equal "BV BG Legal", lookup(html:).attributes[:name]
  end

  test "designates explicit natural persons and preserves unknown or absent registered legal forms" do
    natural_person = with_registry_rows('<tr><td class="RL">Type entiteit:</td><td class="RL">Natuurlijk persoon</td></tr>')
      .sub("TEST CBE Company", "Jan Janssens")
    assert_equal "NP Jan Janssens", lookup(html: natural_person).attributes[:name]
    unknown_form = with_registry_rows('<tr><td class="RL">Rechtsvorm:</td><td class="RL">Onbekende rechtsvorm</td></tr>')
    assert_equal "TEST CBE Company", lookup(html: unknown_form).attributes[:name]
    assert_equal "TEST CBE Company", lookup.attributes[:name]
  end

  test "does not infer the current BV form from a registered legacy BVBA" do
    html = with_registry_rows('<tr><td class="RL">Rechtsvorm:</td><td class="RL">Besloten vennootschap met beperkte aansprakelijkheid</td></tr>')
      .sub("TEST CBE Company", "BG Legal")

    assert_equal "BVBA BG Legal", lookup(html:).attributes[:name]
  end

  test "enforces the stored name limit after adding the registered legal form" do
    html = with_registry_rows('<tr><td class="RL">Rechtsvorm:</td><td class="RL">Besloten vennootschap</td></tr>')
      .sub("TEST CBE Company", "A" * 159)

    assert_equal :unavailable, lookup(html:).status
  end

  test "does not use an establishment address when no registered office is present" do
    html = fixture_html.sub(%r{<tr><td class="RL">Adres van de zetel:</td>.*?</tr>}m, "")
    result = lookup(html:)

    assert_predicate result, :success?
    assert_equal({ name: "TEST CBE Company", enterprise_number: "1234567894" }, result.attributes)
  end

  test "rejects invalid input and public records that do not identify an active requested entity" do
    assert_equal :invalid, lookup(number: "12345678940").status
    assert_equal :not_found, lookup(html: fixture_html.sub("1234.567.894", "0123.456.789")).status
    inactive = fixture_html.sub('<span class="pageactief">Actief</span>', '<span class="pageinactief">Stopgezet</span>')
    assert_equal :not_found, lookup(html: inactive).status
  end

  test "treats malformed, blocked and non-html responses as unavailable" do
    assert_equal :unavailable, lookup(html: "<!doctype html><!ENTITY x SYSTEM 'file:///etc/passwd'>").status
    assert_equal :unavailable, BusinessRegistry::PublicLookup.call(enterprise_number: "1234567894", locale: :nl,
      transport: ->(_uri, _request) { [ 302, fixture_html ] }).status
  end

  test "accepts the actual public page title and ordinary XHTML doctype" do
    html = fixture_html.sub("Gegevens van de geregistreerde entiteit</title>", "Gegevens van de geregistreerde entiteit | KBO Public Search</title>")
    assert_predicate lookup(html:), :success?
    blocked = html.sub("Gegevens van de geregistreerde entiteit | KBO Public Search</title>", "Access denied</title>")
    assert_equal :unavailable, lookup(html: blocked).status
    assert_equal :unavailable, lookup(html: fixture_html.sub("29/10/2026", "31/02/2026")).status
  end

  test "a foreign registered address is left manual without losing the legal name" do
    html = fixture_html.sub("1000&nbsp;Brussel", "1000&nbsp;Brussel<br>France")
    result = lookup(html:)
    assert_predicate result, :success?
    assert_equal({ name: "TEST CBE Company", enterprise_number: "1234567894" }, result.attributes)
  end

  private

  def lookup(number: "1234567894", html: fixture_html)
    BusinessRegistry::PublicLookup.call(enterprise_number: number, locale: :nl,
      transport: ->(_uri, _request) { [ 200, html ] })
  end

  def fixture_html
    file_fixture("kbo_company.html").binread
  end

  def with_registry_rows(*rows)
    fixture_html.sub("<table>", "<table>#{rows.join}")
  end
end
