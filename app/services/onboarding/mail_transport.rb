require "mail"
require "net/smtp"

module Onboarding
  class MailTransport
    class TemporaryFailure < StandardError; end
    class Rejected < StandardError; end

    TRANSIENT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Net::SMTPServerBusy ].freeze

    # Sanitize at the transport boundary, before ActionMailer logs the failed
    # delivery event. SMTP responses can contain addresses or provider details.
    class Smtp < ::Mail::SMTP
      def deliver!(mail)
        super
      rescue *TRANSIENT_ERRORS => error
        Rails.logger.warn("Verification mail transport unavailable: #{error.class}")
        raise TemporaryFailure, "Verification mail transport unavailable", cause: nil
      rescue Net::SMTPError, OpenSSL::SSL::SSLError => error
        Rails.logger.warn("Verification mail transport rejected: #{error.class}")
        raise Rejected, "Verification mail transport rejected", cause: nil
      end
    end

    def self.protect(message)
      transport = message.delivery_method
      message.delivery_method(Smtp, transport.settings) if transport.instance_of?(::Mail::SMTP)
      message
    end
  end
end
