require "test_helper"
require "stringio"

class EmailVerificationDeliveryJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: nil)
    ActionMailer::Base.deliveries.clear
  end

  teardown { ActionMailer::Base.deliveries.clear }

  test "verification uses its scoped job and preserves captured test delivery" do
    assert_enqueued_with(job: EmailVerificationDeliveryJob) do
      EmailVerificationMailer.verify(@user).deliver_later
    end
    assert_emails 1 do
      perform_enqueued_jobs only: EmailVerificationDeliveryJob
    end
    assert_equal [ @user.email_address ], ActionMailer::Base.deliveries.last.to
    assert_equal Mail::TestMailer, ActionMailer::Base.deliveries.last.delivery_method.class
  end

  test "a queued or retried verification skips recipients confirmed or suspended in the meantime" do
    [ { email_verified_at: Time.current }, { email_verified_at: nil, suspended_at: Time.current } ].each do |attributes|
      @user.update!(attributes)
      assert_no_emails { perform_verification }
      assert_no_enqueued_jobs
    end
  end

  test "verification queued for a registration removed by retention is discarded" do
    job = EmailVerificationDeliveryJob.new("EmailVerificationMailer", "verify", "deliver_now", args: [ @user ]).serialize
    @user.destroy!

    assert_no_emails do
      assert_nothing_raised { ActiveJob::Base.execute(job) }
    end
    assert_no_enqueued_jobs
  end

  test "a queued delivery reloads the current address and generates an address-bound link" do
    stale_user = User.find(@user.id)
    previous_token = stale_user.email_verification_token
    @user.update!(email_address: "current-confirmation@example.test")
    assert_emails(1) { perform_verification(stale_user) }
    message = ActionMailer::Base.deliveries.last
    assert_equal [ "current-confirmation@example.test" ], message.to
    url = Nokogiri::HTML(message.html_part.body.decoded).at_css('a[href*="email-verification"]')["href"]
    token = URI(url).path.split("/").last
    assert_equal @user, User.find_by_email_verification_token!(token)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { User.find_by_email_verification_token!(previous_token) }
  end

  test "temporary SMTP failure schedules one bounded sanitized retry with settings preserved" do
    with_smtp_failure(Net::SMTPServerBusy) do |settings, output|
      assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
        perform_verification
      end
      assert_empty ActionMailer::Base.deliveries
      assert_equal settings, @seen_settings
      assert_not_includes output.string, "private SMTP address and response"
      assert_includes output.string, "Onboarding::MailTransport::TemporaryFailure"
    end
  end

  test "the third temporary failure stops retrying and exposes only a fixed error" do
    with_smtp_failure(Net::ReadTimeout) do |_settings, output|
      job = EmailVerificationDeliveryJob.new("EmailVerificationMailer", "verify", "deliver_now", args: [ @user ])
      2.times { assert_enqueued_jobs(1, only: EmailVerificationDeliveryJob) { job.perform_now } }
      clear_enqueued_jobs
      assert_no_enqueued_jobs do
        error = assert_raises(Onboarding::MailTransport::TemporaryFailure) { job.perform_now }
        assert_equal "Verification mail transport unavailable", error.message
        assert_nil error.cause
      end
      assert_not_includes output.string, "private SMTP address and response"
    end
  end

  test "permanent SMTP authentication failure is sanitized without being retried" do
    with_smtp_failure(Net::SMTPAuthenticationError) do |_settings, output|
      assert_no_enqueued_jobs do
        error = assert_raises(Onboarding::MailTransport::Rejected) { perform_verification }
        assert_equal "Verification mail transport rejected", error.message
        assert_nil error.cause
      end
      assert_not_includes output.string, "private SMTP address and response"
    end
  end

  private

  def perform_verification(user = @user)
    EmailVerificationDeliveryJob.perform_now("EmailVerificationMailer", "verify", "deliver_now", args: [ user ])
  end

  def with_smtp_failure(error_class)
    original_delivery_method = EmailVerificationMailer.delivery_method
    original_settings = EmailVerificationMailer.smtp_settings
    original_smtp = Mail::SMTP.instance_method(:deliver!)
    original_rails_logger = Rails.logger
    original_job_logger = ActiveJob::Base.logger
    original_mail_logger = ActionMailer::Base.logger
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger = ActiveJob::Base.logger = ActionMailer::Base.logger = logger
    settings = { address: "smtp.example.invalid", port: 587, domain: "lawrelay.example.invalid",
      user_name: "example", password: "synthetic-only", authentication: :plain, enable_starttls_auto: true,
      open_timeout: 10, read_timeout: 30 }
    EmailVerificationMailer.delivery_method = :smtp
    EmailVerificationMailer.smtp_settings = settings
    observer = self
    Mail::SMTP.define_method(:deliver!) do |_message|
      observer.instance_variable_set(:@seen_settings, self.settings)
      raise error_class, "private SMTP address and response"
    end
    yield Mail::SMTP.new(settings).settings, output
  ensure
    Mail::SMTP.define_method(:deliver!, original_smtp) if original_smtp
    EmailVerificationMailer.delivery_method = original_delivery_method
    EmailVerificationMailer.smtp_settings = original_settings
    Rails.logger = original_rails_logger
    ActiveJob::Base.logger = original_job_logger
    ActionMailer::Base.logger = original_mail_logger
  end
end
