require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "Turbo receives a fresh nonce authorized for scripts and styles" do
    nonces = %w[nl fr de en].map do |locale|
      get root_path(locale:), headers: { "X-Request-ID" => "caller-supplied-id" }
      assert_response :success
      nonce = css_select("meta[name='csp-nonce']").first["content"]
      assert nonce.present?
      assert_not_equal "caller-supplied-id", nonce
      policy = response.headers.fetch("content-security-policy")
      %w[script-src style-src].each do |directive|
        assert_match(/#{directive}[^;]*'nonce-#{Regexp.escape(nonce)}'/, policy)
      end
      assert_not_includes policy, "'unsafe-inline'"
      nonce
    end
    assert_equal 4, nonces.uniq.size
  end
end
