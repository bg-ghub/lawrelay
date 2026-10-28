require "test_helper"

class SensitiveLogFormatterTest < ActiveSupport::TestCase
  test "redacts recovery and verification URL tokens without altering normal paths" do
    formatter = SensitiveLogFormatter.new
    token = "signed_token_value_that_must_not_be_logged"
    %w[email-verification directory-verification passwords].each do |route|
      output = formatter.call("INFO", Time.current, nil, "GET /nl/#{route}/#{token}/edit")
      assert_not_includes output, token
      assert_includes output, "/#{route}/[FILTERED]"
    end
    assert_includes formatter.call("INFO", Time.current, nil, "GET /nl/passwords/new"), "/nl/passwords/new"
  end
end
