require "test_helper"

class BusinessRegistryKboLookupTest < ActiveSupport::TestCase
  test "links directly to a checksum-valid enterprise number on official Public Search" do
    url = BusinessRegistry::KboLookup.url_for(enterprise_number: "0781.961.243", locale: :fr)
    uri = URI(url)

    assert_equal "https", uri.scheme
    assert_equal "kbopub.economie.fgov.be", uri.host
    assert_equal "/kbopub/toonondernemingps.html", uri.path
    assert_equal({ "ondernemingsnummer" => "0781961243", "lang" => "fr" }, URI.decode_www_form(uri.query).to_h)
    assert_nil uri.fragment
    assert_nil uri.userinfo
  end

  test "normalizes the same supported Belgian number formats as the billing form" do
    [ "0781961243", " 0781 961 243 ", "BE0781961243", "be 0781.961.243", "0781-961-243" ].each do |number|
      assert_equal "https://kbopub.economie.fgov.be/kbopub/toonondernemingps.html?ondernemingsnummer=0781961243&lang=nl",
        BusinessRegistry::KboLookup.url_for(enterprise_number: number, locale: :nl)
    end
  end

  test "never builds a link from a malformed or checksum-invalid number" do
    [ nil, "", "0781961244", "07819612430", "781961243", "FR0781961243", "0781961243&lang=en",
      "https://example.test/0781961243", "0781961243#redirect", "0781x961243", "0000000000" ].each do |number|
      assert_nil BusinessRegistry::KboLookup.url_for(enterprise_number: number, locale: :en), number.inspect
    end
  end

  test "supports only official interface locales and falls back to Dutch" do
    %w[nl fr de en].each do |locale|
      assert_equal locale, URI.decode_www_form(URI(BusinessRegistry::KboLookup.url_for(enterprise_number: "0781961243", locale:)).query).to_h.fetch("lang")
    end

    assert_equal "nl", URI.decode_www_form(URI(BusinessRegistry::KboLookup.url_for(enterprise_number: "0781961243", locale: "en&next=evil")).query).to_h.fetch("lang")
  end
end
