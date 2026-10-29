require "test_helper"

class DirectoryDeliveryRetryTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
    @profile = @user.create_lawyer_profile!(bar_association: "OVB", bar_number: "DELIVERY-RETRY",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @user.full_name, directory_email: "official-retry@example.test", directory_checked_at: Time.current,
      directory_identity_digest: "synthetic-proof")
    ActionMailer::Base.deliveries.clear
  end

  teardown { ActionMailer::Base.deliveries.clear }

  test "an unavailable lookup retries then succeeds while permanent results do not retry" do
    statuses = [ :unavailable, :matched, :name_mismatch, :email_missing, :already_claimed ]
    original = Directory::Verification.method(:request!)
    Directory::Verification.define_singleton_method(:request!) do |**|
      Directory::Verification::Result.new(status: statuses.shift, profile: nil)
    end
    job = Directory::VerificationJob.new(@user.id)
    assert_enqueued_jobs(1, only: Directory::VerificationJob) { job.perform_now }
    clear_enqueued_jobs
    4.times { assert_no_enqueued_jobs { job.perform_now } }
    assert_empty statuses
  ensure
    Directory::Verification.define_singleton_method(:request!, original) if original
  end

  test "temporary lookup results stop retrying after three attempts" do
    original = Directory::Verification.method(:request!)
    Directory::Verification.define_singleton_method(:request!) { |**| Directory::Verification::Result.new(status: :unavailable, profile: nil) }
    job = Directory::VerificationJob.new(@user.id)
    2.times { assert_enqueued_jobs(1, only: Directory::VerificationJob) { job.perform_now } }
    clear_enqueued_jobs
    assert_no_enqueued_jobs do
      error = assert_raises(Directory::VerificationJob::TemporarilyUnavailable) { job.perform_now }
      assert_equal "Directory lookup temporarily unavailable", error.message
    end
  ensure
    Directory::Verification.define_singleton_method(:request!, original) if original
  end

  test "official-mail confirmation retries a temporary SMTP failure before recording a successful request" do
    original_mailer = DirectoryVerificationMailer.method(:confirm)
    original_smtp = Mail::SMTP.instance_method(:deliver!)
    message = Mail.new(to: @profile.directory_email, from: "no-reply@example.test", body: "Synthetic confirmation")
    message.delivery_method(:smtp)
    delivery = Object.new
    delivery.define_singleton_method(:message) { message }
    delivery.define_singleton_method(:deliver_now) { message.deliver }
    DirectoryVerificationMailer.define_singleton_method(:confirm) { |*| delivery }
    Mail::SMTP.define_method(:deliver!) { |*| raise Net::ReadTimeout, "private provider details" }

    assert_enqueued_jobs 1, only: Directory::ConfirmationJob do
      Directory::ConfirmationJob.perform_now(@profile.id)
    end
    assert_nil @profile.reload.directory_confirmation_requested_at
    assert_empty ActionMailer::Base.deliveries
    message.delivery_method(:test)
    Directory::ConfirmationJob.perform_now(@profile.id)
    assert @profile.reload.directory_confirmation_requested_at.present?
    assert_equal [ @profile.directory_email ], ActionMailer::Base.deliveries.last.to
  ensure
    Mail::SMTP.define_method(:deliver!, original_smtp) if original_smtp
    DirectoryVerificationMailer.define_singleton_method(:confirm, original_mailer) if original_mailer
  end
end
