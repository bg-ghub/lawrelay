require "mail"
require "net/smtp"

module Onboarding
  class MailTransport
    class TemporaryFailure < StandardError; end
    class Rejected < StandardError; end
    class ConfigurationError < StandardError; end

    TRANSIENT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Net::SMTPServerBusy ].freeze

    # Sanitize at the transport boundary, before ActionMailer logs the failed
    # delivery event. SMTP responses can contain addresses or provider details.
    class Smtp < ::Mail::SMTP
      def deliver!(mail)
        super
      rescue *TRANSIENT_ERRORS => error
        Rails.logger.warn("Mail transport unavailable: #{error.class}")
        raise TemporaryFailure, "Mail transport unavailable", cause: nil
      rescue Net::SMTPError, OpenSSL::SSL::SSLError => error
        Rails.logger.warn("Mail transport rejected: #{error.class}")
        raise Rejected, "Mail transport rejected", cause: nil
      end
    end

    def self.protect(message)
      transport = message.delivery_method
      message.delivery_method(Smtp, transport.settings) if transport.instance_of?(::Mail::SMTP)
      message
    end

    def self.return_path
      if ENV.key?("MAIL_RETURN_PATH")
        raise ConfigurationError, "MAIL_RETURN_PATH must be a single email address" unless valid_return_path_configuration?

        ENV.fetch("MAIL_RETURN_PATH")
      elsif mailbox_address?(ENV["SMTP_USERNAME"])
        ENV.fetch("SMTP_USERNAME")
      end
    end

    def self.valid_return_path_configuration?
      !ENV.key?("MAIL_RETURN_PATH") || mailbox_address?(ENV["MAIL_RETURN_PATH"])
    end

    def self.mailbox_address?(value)
      value.is_a?(String) && value.bytesize <= 254 && !value.match?(/[[:space:][:cntrl:]]/) &&
        value.match?(URI::MailTo::EMAIL_REGEXP) && Mail::Address.new(value).address == value
    rescue Mail::Field::ParseError
      false
    end
    private_class_method :mailbox_address?
  end
end
