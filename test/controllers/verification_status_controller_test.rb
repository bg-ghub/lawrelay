require "test_helper"

class VerificationStatusControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get verification_status_path(locale: :en)

    assert_redirected_to new_session_path(locale: :en)
  end

  test "shows the current verification states" do
    user = users(:one)
    user.update!(email_address: "pending@advocaat.be", email_verified_at: nil)
    firm = Firm.create!(name: "Example Legal", verification_status: "pending")
    user.memberships.create!(firm: firm, role: "owner")
    user.create_lawyer_profile!(bar_association: "BRUSSELS", bar_number: "ONE-1", verification_status: "pending",
      directory_email: "directory@example.test")
    sign_in_as(user)

    get verification_status_path(locale: :en)

    assert_response :success
    assert_select "h2", text: I18n.t("auth.verification_status.check_inbox", locale: :en)
    assert_select ".advocaat-webmail-hint a[href='https://webmail.advocaat.be/']", text: "webmail.advocaat.be"
  end

  test "queues a directory retry without looking up the provider in the request" do
    user = users(:one)
    firm = Firm.create!(name: "Retry Legal", verification_status: "pending")
    user.memberships.create!(firm: firm, role: "owner")
    user.create_lawyer_profile!(bar_association: "OVB", bar_number: "RETRY-1", directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    sign_in_as(user)

    assert_enqueued_with(job: Directory::VerificationJob, args: [ user.id ]) do
      post retry_directory_verification_status_path(locale: :en)
    end

    assert_redirected_to verification_status_path(locale: :en)
  end

  test "pending confirmation offers localized email support without replacing the resend action" do
    user = users(:one)
    user.update!(email_address: "pending@advocaat.be", email_verified_at: nil)
    sign_in_as(user)

    %i[nl fr de en].each do |locale|
      assert_no_enqueued_jobs { get verification_status_path(locale:) }
      assert_response :success
      assert_select ".confirmation-support a[href='mailto:support@lawrelay.be']",
        text: I18n.t("auth.verification_status.confirmation_support_link", locale:), count: 1
      assert_select ".confirmation-delivery-note",
        text: I18n.t("auth.verification_status.advocaat_delivery_notice", locale:), count: 1
      assert_select "form[action='#{verification_status_path(locale:)}']", count: 1
      assert_select ".advocaat-webmail-hint a[href='https://webmail.advocaat.be/']", count: 1
      assert_select ".confirmation-support", text: "Still haven’t received a confirmation e-mail after multiple tries? Send Support an e-mail manually from the address above to support@lawrelay.be." if locale == :en
      assert_not_includes response.body, "Translation missing"
    end
  end

  test "confirmed email does not show confirmation support" do
    user = users(:one)
    user.update!(email_address: "confirmed@advocaat.be")
    user.update!(email_verified_at: Time.current)
    sign_in_as(user)

    get verification_status_path(locale: :en)

    assert_response :success
    assert_select ".confirmation-support", count: 0
    assert_select ".confirmation-delivery-note", count: 0
  end

  test "other email domains keep generic confirmation support without an Advocaat be delivery notice" do
    user = users(:one)
    user.update!(email_verified_at: nil)
    sign_in_as(user)

    %i[nl fr de en].each do |locale|
      get verification_status_path(locale:)

      assert_response :success
      assert_select ".confirmation-support", count: 1
      assert_select ".confirmation-delivery-note", count: 0
    end
  end

  test "a failed email resend stays on the retryable status page without exposing the error" do
    user = users(:one)
    user.update!(email_verified_at: nil)
    sign_in_as(user)
    original = EmailVerificationMailer.method(:verify)
    EmailVerificationMailer.define_singleton_method(:verify) { |*| raise ActiveJob::EnqueueError, "private SMTP user and token" }
    post verification_status_path(locale: :nl)
    assert_redirected_to verification_status_path(locale: :nl)
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :nl), flash[:alert]
    assert_nil flash[:notice]
    assert_not_includes response.body, "private SMTP"
    EmailVerificationMailer.define_singleton_method(:verify, original)

    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      post verification_status_path(locale: :nl)
    end
    assert_equal I18n.t("auth.verification_status.resent", locale: :nl), flash[:notice]
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  test "a rejected directory retry is reported without a false success notice" do
    sign_in_as(users(:one))
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| false }
    post retry_directory_verification_status_path(locale: :en)
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :en), flash[:alert]
    assert_nil flash[:notice]
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end

  test "confirmation resends are limited per account across sessions addresses and page languages" do
    user = users(:one)
    user.update!(email_verified_at: nil)

    with_memory_rate_limit_store do
      %i[nl fr de].each_with_index do |locale, index|
        sign_in_as(user)
        assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ user ] do
          post verification_status_path(locale:), headers: { "REMOTE_ADDR" => "198.51.100.#{index + 1}" }
        end
        assert_redirected_to verification_status_path(locale:)
      end

      user.update!(email_address: "changed-resend@example.test")
      sign_in_as(user)
      assert_no_difference "AuditEvent.count" do
        assert_no_enqueued_jobs do
          post verification_status_path(locale: :en),
            params: { user_id: users(:two).id, email_address: users(:two).email_address },
            headers: { "REMOTE_ADDR" => "198.51.100.99" }
        end
      end
      assert_redirected_to verification_status_path(locale: :en)
      assert_equal I18n.t("auth.verification_status.rate_limited", locale: :en), flash[:alert]

      travel 61.minutes do
        assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ user ] do
          post verification_status_path(locale: :en)
        end
        assert_redirected_to verification_status_path(locale: :en)
      end
    end
  end

  test "lawyers sharing an office IP retain separate confirmation resend quotas" do
    with_memory_rate_limit_store do
      [ users(:one), users(:two) ].each do |user|
        user.update!(email_verified_at: nil)
        sign_in_as(user)
        3.times do
          assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ user ] do
            post verification_status_path(locale: :en), headers: { "REMOTE_ADDR" => "198.51.100.10" }
          end
        end
        assert_no_enqueued_jobs do
          post verification_status_path(locale: :en), headers: { "REMOTE_ADDR" => "198.51.100.10" }
        end
        assert_equal I18n.t("auth.verification_status.rate_limited", locale: :en), flash[:alert]
      end
    end
  end

  test "the shared IP cap limits bulk confirmation requests across accounts" do
    accounts = [ users(:one), users(:two) ] + 2.times.map do |index|
      User.create!(first_name: "Resend", last_name: "Test", email_address: "bulk-resend-#{index}@example.test", password: "password1234")
    end
    with_memory_rate_limit_store do
      accounts.each_with_index do |user, index|
        user.update!(email_verified_at: nil)
        sign_in_as(user)
        (index == 3 ? 1 : 3).times do
          assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ user ] do
            post verification_status_path(locale: :en), headers: { "REMOTE_ADDR" => "198.51.100.11" }
          end
        end
      end

      assert_no_enqueued_jobs do
        post verification_status_path(locale: :en), headers: { "REMOTE_ADDR" => "198.51.100.11" }
      end
      assert_equal I18n.t("auth.verification_status.rate_limited", locale: :en), flash[:alert]
    end
  end

  test "confirmation resends require authentication and do not send for already confirmed accounts" do
    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs { post verification_status_path(locale: :en) }
    end
    assert_redirected_to new_session_path(locale: :en)

    sign_in_as(users(:one))
    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs { post verification_status_path(locale: :en) }
    end
    assert_redirected_to verification_status_path(locale: :en)
  end

  test "eligible resend requests record domain and queue an operator alert by audit identifier" do
    user = users(:one)
    user.update!(email_address: "pending@advocaat.be", email_verified_at: nil)
    sign_in_as(user)

    assert_difference "AuditEvent.where(action: 'account.confirmation_resend_requested').count", 1 do
      assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ user ] do
        post verification_status_path(locale: :en)
      end
    end

    event = AuditEvent.where(action: "account.confirmation_resend_requested").order(:id).last
    assert_equal user, event.auditable
    assert_equal user, event.actor_user
    assert_equal({ "recipient_domain" => "advocaat.be", "delivery_queued" => true }, event.metadata)
    assert_enqueued_with(job: ConfirmationResendAlertJob, args: [ event.id ])
    assert_equal I18n.t("auth.verification_status.resent", locale: :en), flash[:notice]
  end

  test "operator alert enqueue failure does not block confirmation mail or remove the audit" do
    user = users(:one)
    user.update!(email_verified_at: nil)
    sign_in_as(user)
    original = ConfirmationResendAlertJob.method(:perform_later)
    ConfirmationResendAlertJob.define_singleton_method(:perform_later) { |*| raise ActiveJob::EnqueueError, "private mail context" }

    assert_difference "AuditEvent.where(action: 'account.confirmation_resend_requested').count", 1 do
      assert_enqueued_email_with EmailVerificationMailer, :verify, args: [ user ] do
        post verification_status_path(locale: :en)
      end
    end
    assert_equal I18n.t("auth.verification_status.resent", locale: :en), flash[:notice]
    event = AuditEvent.where(action: "account.confirmation_resend_requested").order(:id).last
    assert_equal true, event.metadata["delivery_queued"]
    assert_not_includes response.body, "private mail context"
  ensure
    ConfirmationResendAlertJob.define_singleton_method(:perform_later, original) if original
  end

  private

  def with_memory_rate_limit_store
    original = VerificationStatusController.instance_method(:rate_limiting)
    store = ActiveSupport::Cache::MemoryStore.new
    VerificationStatusController.define_method(:rate_limiting) do |**arguments|
      original.bind_call(self, **arguments.merge(store:))
    end
    VerificationStatusController.send(:private, :rate_limiting)
    yield
  ensure
    VerificationStatusController.define_method(:rate_limiting, original) if original
    VerificationStatusController.send(:private, :rate_limiting)
  end
end
