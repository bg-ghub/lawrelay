require "test_helper"

class SensitiveLogFormatterTest < ActiveSupport::TestCase
  test "redaction retains tagged logging support" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.formatter = SensitiveLogFormatter.new
    tagged_logger = ActiveSupport::TaggedLogging.new(logger)

    tagged_logger.tagged("request-id") { tagged_logger.info("GET /nl/passwords/long_signed_recovery_token_value/edit") }

    assert_includes output.string, "[request-id]"
    assert_includes output.string, "/passwords/[FILTERED]/edit"
    assert_not_includes output.string, "long_signed_recovery_token_value"
  end

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
