require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::VerificationDeliveriesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @account = create_marketplace_account(prefix: "verification-resend", verified: false, email_verified: false)
    @user = @account.user
    match_directory!
    sign_in_as(@admin, admin_mfa: true)
  end

  test "verification resends require an administrator with fresh MFA" do
    [ nil, @user, @admin ].each do |actor|
      actor ? sign_in_as(actor) : sign_out
      expected_path = if actor.nil?
        admin_login_path(locale: :en)
      elsif actor.system_admin?
        admin_mfa_setup_path(locale: :en)
      else
        root_path(locale: :en)
      end

      [ @user.public_id, @user.id ].each do |identifier|
        assert_no_difference "AuditEvent.count" do
          assert_no_enqueued_jobs do
            post resend_verification_admin_user_path(identifier, locale: :en)
          end
        end
        assert_redirected_to expected_path
      end
    end
  end

  test "UUID and legacy numeric posts resend to the same account without changing verification evidence" do
    original_user = @user.attributes
    original_profile = @account.profile.attributes

    [ @user.public_id, @user.id ].each do |identifier|
      assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
        assert_no_enqueued_jobs only: [ Directory::VerificationJob, Directory::ConfirmationJob ] do
          post resend_verification_admin_user_path(identifier, locale: :en)
        end
      end
      assert_redirected_to admin_user_path(@user, locale: :en)
      assert_equal I18n.t("admin.users.verification_delivery.queued", locale: :en), flash[:notice]
      assert_nil flash[:alert]
    end

    assert_equal original_user, @user.reload.attributes
    assert_equal original_profile, @account.profile.reload.attributes
    events = AuditEvent.where(auditable: @user, action: "user.verification_resent")
    assert_equal 2, events.count
    events.each do |event|
      assert_equal @admin, event.actor_user
      assert_equal [ "channels" ], event.metadata.keys
      assert_equal [ "account_email" ], event.metadata.fetch("channels")
    end
  end

  test "a confirmed account with a distinct pending official address queues only its confirmation" do
    @user.update!(email_verified_at: Time.current)
    match_directory!(email: "official-confirmation@example.test")
    assert @account.profile.directory_confirmation_required?
    original_profile = @account.profile.attributes

    assert_enqueued_with(job: Directory::ConfirmationJob, args: [ @account.profile.id ]) do
      assert_no_enqueued_jobs only: [ EmailVerificationDeliveryJob, Directory::VerificationJob ] do
        post resend_verification_admin_user_path(@user, locale: :en)
      end
    end
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal I18n.t("admin.users.verification_delivery.queued", locale: :en), flash[:notice]
    assert_equal original_profile, @account.profile.reload.attributes
    assert_equal [ "directory_email" ], AuditEvent.find_by!(auditable: @user, action: "user.verification_resent").metadata.fetch("channels")
  end

  test "an account without a directory match can resend its account mail while showing the outstanding check" do
    @account.profile.update!(directory_profile_id: nil, directory_profile_url: nil, directory_name: nil, directory_email: nil,
      directory_checked_at: nil, directory_identity_digest: nil)

    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      assert_no_enqueued_jobs only: [ Directory::VerificationJob, Directory::ConfirmationJob ] do
        post resend_verification_admin_user_path(@user, locale: :en)
      end
    end
    assert_equal I18n.t("admin.users.verification_delivery.queued_directory_pending", locale: :en), flash[:notice]
    assert_not @account.profile.reload.directory_matched?
    assert_not @user.reload.email_verified?
  end

  test "already confirmed recipients do not receive duplicate mail" do
    @user.update!(email_verified_at: Time.current)
    @account.profile.update!(directory_email_verified_at: Time.current, verification_status: "verified", verified_at: Time.current)

    assert_ineligible_resend
  end

  test "a matching official address never receives a redundant directory confirmation" do
    @user.update!(email_verified_at: Time.current)
    assert_not @account.profile.directory_confirmation_required?

    assert_ineligible_resend
  end

  test "manual email review states do not bypass directory confirmation eligibility" do
    @user.update!(email_verified_at: Time.current)
    match_directory!(email: "official-under-review@example.test")
    %w[pending approved rejected].each do |status|
      @account.profile.update!(email_review_status: status)
      assert_not @account.profile.directory_confirmation_required?
      assert_ineligible_resend
    end
  end

  test "suspended and erased accounts cannot receive verification mail" do
    [ { suspended_at: Time.current }, { suspended_at: nil, erased_at: Time.current } ].each do |attributes|
      @user.update!(attributes)
      assert_ineligible_resend
    end
  end

  test "protected professional profiles and firms cannot receive verification mail" do
    [ "rejected", "suspended" ].each do |status|
      @account.profile.update!(verification_status: status)
      assert_ineligible_resend
      @account.profile.update!(verification_status: "pending")
      @account.firm.update!(verification_status: status)
      assert_ineligible_resend
      @account.firm.update!(verification_status: "pending")
    end
  end

  test "administrator targets are excluded from the resend endpoint" do
    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs { post resend_verification_admin_user_path(@admin, locale: :en) }
    end
    assert_response :not_found
  end

  test "three resends per administrator are allowed in fifteen minutes across targets" do
    with_memory_rate_limit_store do
      3.times do |index|
        target = create_marketplace_account(prefix: "admin-limit-#{index}", email_verified: false).user
        assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
          post resend_verification_admin_user_path(target, locale: :en)
        end
        follow_redirect!
      end

      assert_throttled_resend
      travel 16.minutes do
        assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
          post resend_verification_admin_user_path(@user, locale: :en)
        end
        assert_equal I18n.t("admin.users.verification_delivery.queued", locale: :en), flash[:notice]
      end
    end
  end

  test "three resends per target are allowed across different administrators" do
    with_memory_rate_limit_store do
      3.times do |index|
        actor = User.create!(first_name: "Administrator", last_name: index.to_s,
          email_address: "resend-admin-#{index}@example.test", password: "password1234", system_role: "admin")
        sign_in_as(actor, admin_mfa: true)
        assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
          identifier = index.even? ? @user.public_id : @user.id
          post resend_verification_admin_user_path(identifier, locale: :en)
        end
        follow_redirect!
      end

      sign_in_as(@admin, admin_mfa: true)
      assert_throttled_resend
    end
  end

  test "an account-mail queue error reports failure without auditing a successful resend" do
    original = EmailVerificationMailer.method(:verify)
    EmailVerificationMailer.define_singleton_method(:verify) { |*| raise ActiveJob::EnqueueError, "private recipient and token" }

    assert_no_difference "AuditEvent.where(action: 'user.verification_resent').count" do
      assert_no_enqueued_jobs { post resend_verification_admin_user_path(@user, locale: :en) }
    end
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal I18n.t("admin.users.verification_delivery.unavailable", locale: :en), flash[:alert]
    assert_nil flash[:notice]
    assert_not_includes response.body, "private recipient"
    assert_not @user.reload.email_verified?
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  test "a directory-mail queue rejection reports failure without a success notice" do
    @user.update!(email_verified_at: Time.current)
    match_directory!(email: "official-unavailable@example.test")
    original = Directory::ConfirmationJob.method(:perform_later)
    Directory::ConfirmationJob.define_singleton_method(:perform_later) { |*| false }

    assert_no_difference "AuditEvent.where(action: 'user.verification_resent').count" do
      assert_no_enqueued_jobs { post resend_verification_admin_user_path(@user, locale: :en) }
    end
    assert_equal I18n.t("admin.users.verification_delivery.unavailable", locale: :en), flash[:alert]
    assert_nil flash[:notice]
    assert_nil @account.profile.reload.directory_confirmation_requested_at
  ensure
    Directory::ConfirmationJob.define_singleton_method(:perform_later, original) if original
  end

  test "a partial queue failure audits only the account mail that was queued" do
    match_directory!(email: "official-partial-failure@example.test")
    original = Directory::ConfirmationJob.method(:perform_later)
    Directory::ConfirmationJob.define_singleton_method(:perform_later) { |*| false }

    assert_difference "AuditEvent.where(action: 'user.verification_resent').count", 1 do
      assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
        assert_no_enqueued_jobs only: Directory::ConfirmationJob do
          post resend_verification_admin_user_path(@user, locale: :en)
        end
      end
    end
    assert_equal I18n.t("admin.users.verification_delivery.unavailable", locale: :en), flash[:alert]
    assert_nil flash[:notice]
    event = AuditEvent.find_by!(auditable: @user, action: "user.verification_resent")
    assert_equal({ "channels" => [ "account_email" ] }, event.metadata)
    assert_not @user.reload.email_verified?
    assert_nil @account.profile.reload.directory_email_verified_at
  ensure
    Directory::ConfirmationJob.define_singleton_method(:perform_later, original) if original
  end

  test "the resend form uses a POST action and renders in every interface language" do
    %w[nl fr de en].each do |locale|
      get admin_user_path(@user, locale:)
      assert_response :success
      assert_select "form[action='#{resend_verification_admin_user_path(@user, locale:)}'][method='post']" do
        assert_select "button", text: I18n.t("admin.users.verification_delivery.action", locale:)
      end
      assert_not_includes response.body, "translation missing"
    end
  end

  test "cross-site resend requests are rejected before queuing or auditing" do
    previous = Admin::UsersController.allow_forgery_protection
    Admin::UsersController.allow_forgery_protection = true

    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs do
        post resend_verification_admin_user_path(@user, locale: :en), headers: { "Origin" => "https://unrelated.example" }
      end
    end
    assert_response :unprocessable_content
    assert_not @user.reload.email_verified?
  ensure
    Admin::UsersController.allow_forgery_protection = previous
  end

  private

  def with_memory_rate_limit_store
    original = Admin::UsersController.instance_method(:rate_limiting)
    store = ActiveSupport::Cache::MemoryStore.new
    Admin::UsersController.define_method(:rate_limiting) do |**arguments|
      original.bind_call(self, **arguments.merge(store:))
    end
    Admin::UsersController.send(:private, :rate_limiting)
    yield
  ensure
    Admin::UsersController.define_method(:rate_limiting, original) if original
    Admin::UsersController.send(:private, :rate_limiting)
  end

  def match_directory!(email: @user.email_address)
    @account.profile.update!(
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @user.full_name, directory_email: email, directory_checked_at: Time.current,
      directory_identity_digest: "synthetic-evidence", directory_email_verified_at: nil)
  end

  def assert_ineligible_resend
    assert_no_difference "AuditEvent.where(action: 'user.verification_resent').count" do
      assert_no_enqueued_jobs { post resend_verification_admin_user_path(@user, locale: :en) }
    end
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal I18n.t("admin.users.verification_delivery.ineligible", locale: :en), flash[:alert]
    assert_nil flash[:notice]
  end

  def assert_throttled_resend
    assert_no_difference "AuditEvent.where(action: 'user.verification_resent').count" do
      assert_no_enqueued_jobs { post resend_verification_admin_user_path(@user, locale: :en) }
    end
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal I18n.t("admin.users.verification_delivery.throttled", locale: :en), flash[:alert]
    assert_nil flash[:notice]
  end
end
