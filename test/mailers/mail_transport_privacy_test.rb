require "test_helper"
require "stringio"
require_relative "../../lib/sensitive_log_formatter"
require_relative "../support/marketplace_test_factory"

class MailTransportPrivacyTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "smtp-owner")
    @candidate = create_marketplace_account(prefix: "smtp-candidate")
    @assignment = create_assignment_for(@owner)
    @proposal = create_proposal_for(@assignment, @candidate)
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
  end

  teardown { ActionMailer::Base.deliveries.clear }

  test "every transactional mailer sanitizes a permanent SMTP failure at delivery" do
    profile = @owner.profile
    directory_id = SecureRandom.uuid
    profile.update!(directory_profile_id: directory_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{directory_id}",
      directory_name: @owner.user.full_name, directory_email: @owner.user.email_address,
      directory_checked_at: Time.current, directory_identity_digest: "synthetic", email_review_status: "approved")
    profile.update!(email_review_email_address: @owner.user.email_address,
      email_review_identity_digest: profile.email_review_current_identity_digest)
    run = RegistryStatusRun.new
    run.define_singleton_method(:new_findings_count) { 1 }
    deliveries = [
      [ PasswordsMailer, -> { PasswordsMailer.reset(@owner.user) } ],
      [ EmailVerificationMailer, -> { EmailVerificationMailer.verify(@owner.user) } ],
      [ DirectoryVerificationMailer, -> { DirectoryVerificationMailer.confirm(profile) } ],
      [ EmailAccessReviewMailer, -> { EmailAccessReviewMailer.decision(profile) } ],
      [ MarketplaceMailer, -> { MarketplaceMailer.new_proposal(@proposal) } ],
      [ RegistryStatusMailer, -> { RegistryStatusMailer.daily_alert(run) } ]
    ]

    deliveries.each do |mailer, build|
      with_smtp_failure(mailer, Net::SMTPAuthenticationError) do |output|
        error = assert_raises(Onboarding::MailTransport::Rejected) { build.call.deliver_now }
        assert_equal "Mail transport rejected", error.message
        assert_nil error.cause
        assert_not_includes output.string, "private-recipient@example.test"
        assert_equal @expected_settings, @seen_settings
      end
    end
  end

  test "notification SMTP retry logs and outbox metadata contain only sanitized errors" do
    event = @owner.user.notifications.find_by!(kind: "new_proposal", subject: @proposal)
    with_smtp_failure(MarketplaceMailer, Net::SMTPServerBusy) do |output|
      assert_enqueued_jobs 1, only: NotificationEmailDeliveryJob do
        NotificationEmailDeliveryJob.perform_now(event.id)
      end
      assert_equal "pending", event.reload.email_status
      assert_equal "Onboarding::MailTransport::TemporaryFailure", event.email_status_reason
      assert_not_includes output.string, "private-recipient@example.test"
      assert_includes output.string, "Onboarding::MailTransport::TemporaryFailure"
      assert_nil event.email_sent_at
    end
  end

  test "password reset failures keep the existing job policy and never log the SMTP response" do
    with_smtp_failure(PasswordsMailer, Net::SMTPFatalError) do |output|
      assert_no_enqueued_jobs do
        error = assert_raises(Onboarding::MailTransport::Rejected) do
          ActionMailer::MailDeliveryJob.perform_now("PasswordsMailer", "reset", "deliver_now", args: [ @owner.user ])
        end
        assert_nil error.cause
      end
      assert_not_includes output.string, "private-recipient@example.test"
      assert_includes output.string, "Mail transport rejected"
    end
  end

  test "captured delivery and already protected SMTP transports are preserved" do
    message = Mail.new
    message.delivery_method(:test)
    captured = message.delivery_method
    Onboarding::MailTransport.protect(message)
    assert_same captured, message.delivery_method

    message.delivery_method(:smtp)
    Onboarding::MailTransport.protect(message)
    protected_transport = message.delivery_method
    Onboarding::MailTransport.protect(message)
    assert_same protected_transport, message.delivery_method
    assert_instance_of Onboarding::MailTransport::Smtp, protected_transport
  end

  private

  def with_smtp_failure(mailer, error_class)
    original_delivery_method, original_settings = mailer.delivery_method, mailer.smtp_settings
    original_smtp = Mail::SMTP.instance_method(:deliver!)
    original_rails_logger, original_job_logger, original_mail_logger = Rails.logger, ActiveJob::Base.logger, ActionMailer::Base.logger
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::INFO
    logger.formatter = SensitiveLogFormatter.new
    Rails.logger = ActionMailer::Base.logger = logger
    ActiveJob::Base.logger = ActiveSupport::TaggedLogging.new(logger)
    settings = { address: "smtp.example.invalid", port: 587, user_name: "test", password: "synthetic-only",
      authentication: :plain, enable_starttls: true, enable_starttls_auto: false }
    mailer.delivery_method, mailer.smtp_settings = :smtp, settings
    @expected_settings = Mail::SMTP.new(settings).settings
    @seen_settings = nil
    observer = self
    Mail::SMTP.define_method(:deliver!) do |_message|
      observer.instance_variable_set(:@seen_settings, self.settings)
      raise error_class, "550 private-recipient@example.test private SMTP response"
    end
    yield output
  ensure
    Mail::SMTP.define_method(:deliver!, original_smtp) if original_smtp
    mailer.delivery_method, mailer.smtp_settings = original_delivery_method, original_settings
    Rails.logger, ActiveJob::Base.logger, ActionMailer::Base.logger = original_rails_logger, original_job_logger, original_mail_logger
  end
end
