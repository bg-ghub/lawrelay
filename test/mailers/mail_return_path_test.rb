require "test_helper"

class MailReturnPathTest < ActiveSupport::TestCase
  setup do
    @environment = ENV.to_h.slice("MAIL_RETURN_PATH", "SMTP_USERNAME")
    ENV.delete("MAIL_RETURN_PATH")
    ENV.delete("SMTP_USERNAME")
  end

  teardown do
    %w[MAIL_RETURN_PATH SMTP_USERNAME].each do |name|
      @environment.key?(name) ? ENV[name] = @environment.fetch(name) : ENV.delete(name)
    end
  end

  test "the monitored SMTP mailbox receives bounces without changing the public sender" do
    ENV["SMTP_USERNAME"] = "admin@lawrelay.test"
    message = EmailVerificationMailer.verify(users(:one)).message

    assert_equal "admin@lawrelay.test", message.smtp_envelope_from
    assert_equal [ "no-reply@lawrelay.be" ], message.from
    assert_equal "LawRelay", message[:from].display_names.first
    assert_empty ActionMailer::Base.deliveries
  end

  test "an explicit return path takes priority for all inherited mailers" do
    ENV["SMTP_USERNAME"] = "admin@lawrelay.test"
    ENV["MAIL_RETURN_PATH"] = "bounces@lawrelay.test"

    [ EmailVerificationMailer.verify(users(:one)), PasswordsMailer.reset(users(:one)) ].each do |delivery|
      message = delivery.message
      assert_equal "bounces@lawrelay.test", message.smtp_envelope_from
      assert_equal [ "no-reply@lawrelay.be" ], message.from
    end
    assert Onboarding::MailTransport.valid_return_path_configuration?
  end

  test "non-email provider credentials preserve the sender fallback" do
    [ nil, "apikey", "private key", "admin@lawrelay.test,other@lawrelay.test", "admin@lawrelay.test\r\nBcc: other@lawrelay.test" ].each do |username|
      username ? ENV["SMTP_USERNAME"] = username : ENV.delete("SMTP_USERNAME")
      message = EmailVerificationMailer.verify(users(:one)).message

      assert_nil message.return_path
      assert_equal "no-reply@lawrelay.be", message.smtp_envelope_from
    end
  end

  test "malformed explicit return paths fail with a fixed value-free error" do
    ENV["SMTP_USERNAME"] = "admin@lawrelay.test"
    [ "", " ", "apikey", "LawRelay <bounces@lawrelay.test>", "a@lawrelay.test,b@lawrelay.test",
      "private@lawrelay.test\r\nBcc: other@lawrelay.test", "x" * 250 + "@x.test" ].each do |address|
      ENV["MAIL_RETURN_PATH"] = address

      assert_not Onboarding::MailTransport.valid_return_path_configuration?
      error = assert_raises(Onboarding::MailTransport::ConfigurationError) do
        EmailVerificationMailer.verify(users(:one)).message
      end
      assert_equal "MAIL_RETURN_PATH must be a single email address", error.message
      assert_nil error.cause
    end
  end
end
