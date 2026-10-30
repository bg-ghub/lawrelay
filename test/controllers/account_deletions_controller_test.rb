require "test_helper"
require_relative "../support/marketplace_test_factory"

class AccountDeletionsControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.use_transactional_tests = false

  def before_setup
    clear_disposable_database
    super
  end

  def after_teardown
    super
  ensure
    clear_disposable_database
  end

  setup do
    @account = create_marketplace_account(prefix: "self-delete")
    @other = create_marketplace_account(prefix: "self-delete-other")
    @ledger = Struct.new(:entries) do
      def stage!(user, erased_at:)
        entries << { "user_id" => user.id, "user_created_at" => user.created_at.utc.iso8601(6), "erased_at" => erased_at.utc.iso8601(6) }
        "self-service-operation"
      end

      def commit!(_operation) = true
      def abort!(_operation) = entries.clear
    end.new([])
    sign_in_as(@account.user)
  end

  test "a member can delete their own account with a password and durable ledger entry" do
    with_ledger do
      assert_difference([ "PrivacyRequest.count", "AuditEvent.where(action: 'privacy.account_erased').count" ], 1) do
        delete account_deletion_path(locale: :en), params: {
          current_password: "password1234", confirm_delete_account: "1", user_id: @other.user.id
        }
      end
    end

    assert_redirected_to root_path(locale: :en)
    assert_not @account.user.reload.active?
    assert @other.user.reload.active?
    assert_equal [ @account.user.id ], @ledger.entries.pluck("user_id")
    request_record = @account.user.privacy_requests.sole
    assert_equal "completed", request_record.status
    assert_equal @account.user.id, request_record.handled_by_user_id
    assert AuditEvent.exists?(auditable: @account.user, action: "privacy.account_erased", actor_user: @account.user)

    get settings_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
  end

  test "a ledger finalization failure after the SQL erasure preserves the completed request and signs the member out" do
    extra_session = @account.user.sessions.create!
    @ledger.define_singleton_method(:commit!) { |_operation| raise Privacy::ErasureLedger::UnsafeLedger, "Marker unavailable" }

    with_ledger do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
    end

    assert_redirected_to root_path(locale: :en)
    assert_equal I18n.t("account_deletion.notices.deleted", locale: :en), flash[:notice]
    assert_not @account.user.reload.active?
    assert_not Session.exists?(extra_session.id)
    assert_empty @account.user.sessions
    request_record = @account.user.privacy_requests.sole
    assert_equal "completed", request_record.status
    assert_equal [ @account.user.id ], @ledger.entries.pluck("user_id")
    get settings_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
  end

  test "a ledger staging failure leaves the member active and reports the service error" do
    @ledger.define_singleton_method(:stage!) { |_user, erased_at:| raise Privacy::ErasureLedger::UnsafeLedger, "Ledger unavailable" }

    with_ledger do
      assert_no_difference([ "PrivacyRequest.count", "AuditEvent.where(action: 'privacy.account_erased').count" ]) do
        delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
      end
    end

    assert_response :service_unavailable
    assert @account.user.reload.active?
    assert_empty @account.user.privacy_requests
  end

  test "wrong password or a forged user id does not erase either account" do
    assert_no_difference([ "PrivacyRequest.count", "AuditEvent.where(action: 'privacy.account_erased').count" ]) do
      delete account_deletion_path(locale: :en), params: {
        current_password: "wrong", confirm_delete_account: "1", user_id: @other.user.id
      }
    end

    assert_response :unprocessable_content
    assert @account.user.reload.active?
    assert @other.user.reload.active?
  end

  test "the explicit checkbox is required" do
    assert_no_difference "PrivacyRequest.count" do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234" }
    end

    assert_response :unprocessable_content
    assert @account.user.reload.active?
  end

  test "guests cannot access the deletion form or submit it" do
    sign_out

    get account_deletion_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
    assert_redirected_to new_session_path(locale: :en)
    assert @account.user.reload.active?
  end

  test "cross-site deletion request is rejected before it reaches the erasure service" do
    previous = AccountDeletionsController.allow_forgery_protection
    AccountDeletionsController.allow_forgery_protection = true

    assert_no_difference [ "PrivacyRequest.count", "AuditEvent.where(action: 'privacy.account_erased').count" ] do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" },
        headers: { "Origin" => "https://unrelated.example" }
    end
    assert_response :unprocessable_content
    assert @account.user.reload.active?
  ensure
    AccountDeletionsController.allow_forgery_protection = previous
  end

  test "an administrator cannot use the member account-deletion route" do
    @account.user.update!(system_role: "admin")
    sign_in_as(@account.user, admin_mfa: true)

    get account_deletion_path(locale: :en)
    assert_response :forbidden
    delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
    assert_response :forbidden
    assert @account.user.reload.active?
  end

  test "the admin host never exposes the member account-deletion route" do
    @account.user.update!(system_role: "admin")
    sign_in_as(@account.user, admin_mfa: true)
    host! SiteHosts.admin_host

    get account_deletion_path(locale: :en)

    assert_response :see_other
    assert_equal SiteHosts.main_url(account_deletion_path(locale: :en)), response.location
    assert @account.user.reload.active?
  end

  test "a member with two-factor authentication must complete the challenge first" do
    secret = @account.user.begin_two_factor_setup!(password: "password1234")
    @account.user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_in_as(@account.user)

    get account_deletion_path(locale: :en)
    assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
    assert @account.user.reload.active?
  end

  test "open work remains a clear, safe block" do
    create_assignment_for(@account)

    with_ledger do
      assert_no_difference "PrivacyRequest.count" do
        delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
      end
    end

    assert_response :unprocessable_content
    assert_select ".flash-message span", text: I18n.t("account_deletion.notices.open_work", locale: :en)
    assert @account.user.reload.active?
  end

  test "a retention hold safely blocks self-service deletion" do
    admin = create_marketplace_account(prefix: "hold-operator", system_role: "admin").user
    admin.update!(admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    RetentionHold.create!(subject: @account.user, actor: admin, reason: "Synthetic dispute hold", expires_at: 1.day.from_now)

    with_ledger do
      assert_no_difference "PrivacyRequest.count" do
        delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
      end
    end

    assert_response :unprocessable_content
    assert_select ".flash-message span", text: I18n.t("account_deletion.notices.held", locale: :en)
    assert @account.user.reload.active?
  end

  private

  def with_ledger
    original = Privacy::ErasureLedger.method(:new)
    ledger = @ledger
    Privacy::ErasureLedger.define_singleton_method(:new) { |*| ledger }
    yield
  ensure
    Privacy::ErasureLedger.define_singleton_method(:new) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) } if original
  end

  def clear_disposable_database
    connection = ApplicationRecord.connection
    connection.disable_referential_integrity do
      (connection.tables - %w[schema_migrations ar_internal_metadata]).each do |table|
        connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
      end
    end
    ActiveRecord::FixtureSet.reset_cache
  end
end
