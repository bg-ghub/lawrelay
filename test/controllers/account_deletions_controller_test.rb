require "test_helper"
require_relative "../support/marketplace_test_factory"

class AccountDeletionsControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @account = create_marketplace_account(prefix: "self-delete")
    @other = create_marketplace_account(prefix: "self-delete-other")
    sign_in_as(@account.user)
  end

  test "a member schedules their own deletion without erasing data" do
    other_session = @account.user.sessions.create!
    original_email = @account.user.email_address
    assert_difference "AccountDeletionRequest.count", 1 do
      assert_no_difference [ "PrivacyRequest.count", "AuditEvent.where(action: 'privacy.account_erased').count" ] do
        delete account_deletion_path(locale: :en), params: {
          current_password: "password1234", confirm_delete_account: "1", user_id: @other.user.id
        }
      end
    end
    assert_redirected_to new_session_path(locale: :en)
    member = @account.user.reload
    assert member.deletion_pending?
    assert_not member.active?
    assert_nil member.erased_at
    assert_equal original_email, member.email_address
    assert_equal member.deletion_requested_at + 30.days, member.deletion_scheduled_at
    assert_not Session.exists?(other_session.id)
    assert_empty member.sessions
    assert @other.user.reload.active?
    assert_equal I18n.t("account_deletion.notices.scheduled", locale: :en), flash[:notice]
  end

  test "wrong password and missing confirmation leave both accounts unchanged" do
    [ { current_password: "wrong", confirm_delete_account: "1" }, { current_password: "password1234" } ].each do |parameters|
      assert_no_difference "AccountDeletionRequest.count" do
        delete account_deletion_path(locale: :en), params: parameters.merge(user_id: @other.user.id)
      end
      assert_response :unprocessable_content
      assert @account.user.reload.active?
      assert @other.user.reload.active?
    end
  end

  test "guests cannot access or submit account deletion" do
    sign_out
    get account_deletion_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert_no_difference "AccountDeletionRequest.count" do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
    end
    assert_redirected_to new_session_path(locale: :en)
  end

  test "CSRF protection rejects a cross-site deletion request" do
    previous = AccountDeletionsController.allow_forgery_protection
    AccountDeletionsController.allow_forgery_protection = true
    assert_no_difference "AccountDeletionRequest.count" do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" },
        headers: { "Origin" => "https://unrelated.example" }
    end
    assert_response :unprocessable_content
    assert @account.user.reload.active?
  ensure
    AccountDeletionsController.allow_forgery_protection = previous
  end

  test "administrators cannot use member deletion or cancellation" do
    @account.user.update!(system_role: "admin")
    sign_in_as(@account.user, admin_mfa: true)
    assert_no_difference "AccountDeletionRequest.count" do
      get account_deletion_path(locale: :en)
      assert_response :forbidden
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
      assert_response :forbidden
      post cancel_account_deletion_path(locale: :en), params: { current_password: "password1234" }
      assert_response :forbidden
    end
  end

  test "admin host redirects member deletion to the main site" do
    host! SiteHosts.admin_host
    get account_deletion_path(locale: :en)
    assert_response :see_other
    assert_equal SiteHosts.main_url(account_deletion_path(locale: :en)), response.location
  end

  test "open work keeps the member active" do
    create_assignment_for(@account)
    assert_no_difference "AccountDeletionRequest.count" do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
    end
    assert_response :unprocessable_content
    assert_select ".flash-message span", text: I18n.t("account_deletion.notices.open_work", locale: :en)
    assert @account.user.reload.active?
  end

  test "a retention hold blocks scheduling before account access changes" do
    admin = create_marketplace_account(prefix: "deletion-hold-admin", system_role: "admin").user
    admin.update!(admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    RetentionHold.create!(subject: @account.user, actor: admin, reason: "Synthetic preservation hold", expires_at: 1.day.from_now)
    assert_no_difference "AccountDeletionRequest.count" do
      delete account_deletion_path(locale: :en), params: { current_password: "password1234", confirm_delete_account: "1" }
    end
    assert_response :unprocessable_content
    assert @account.user.reload.active?
    assert_select ".flash-message span", text: I18n.t("account_deletion.notices.held", locale: :en)
  end

  test "cross-site cancellation cannot reactivate a pending account" do
    request = schedule_deletion
    sign_in_as(@account.user.reload)
    previous = AccountDeletionsController.allow_forgery_protection
    AccountDeletionsController.allow_forgery_protection = true
    post cancel_account_deletion_path(locale: :en), params: { current_password: "password1234" },
      headers: { "Origin" => "https://unrelated.example" }
    assert_response :unprocessable_content
    assert @account.user.reload.deletion_pending?
    assert_nil request.reload.cancelled_at
  ensure
    AccountDeletionsController.allow_forgery_protection = previous
  end

  test "a pending member signs in only to the recovery page and can still use privacy requests" do
    schedule_deletion
    post session_path(locale: :en), params: { email_address: @account.user.email_address, password: "password1234" }
    assert_redirected_to account_deletion_path(locale: :en)
    get account_deletion_path(locale: :en)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "form[action='#{cancel_account_deletion_path(locale: :en)}']"
    [ dashboard_path(locale: :en), settings_path(locale: :en), assignments_path(locale: :en), two_factor_authentication_path(locale: :en) ].each do |path|
      get path
      assert_redirected_to account_deletion_path(locale: :en)
    end
    get privacy_requests_path(locale: :en)
    assert_response :success
    post privacy_requests_path(locale: :en), params: { privacy_request: { kind: "deletion", details: "Please review immediate erasure." } }
    assert_redirected_to privacy_requests_path(locale: :en)
    assert @account.user.reload.deletion_pending?
  end

  test "cancellation requires the current password and does not act on a forged user id" do
    request = schedule_deletion
    sign_in_as(@account.user.reload)
    post cancel_account_deletion_path(locale: :en), params: { current_password: "wrong", user_id: @other.user.id }
    assert_response :unprocessable_content
    assert @account.user.reload.deletion_pending?
    assert_nil request.reload.cancelled_at
    post cancel_account_deletion_path(locale: :en), params: { current_password: "password1234", user_id: @other.user.id }
    assert_redirected_to new_session_path(locale: :en)
    assert @account.user.reload.active?
    assert_not @account.user.deletion_pending?
    assert request.reload.cancelled_at
    assert_empty @account.user.sessions
    assert @other.user.reload.active?
  end

  test "pending recovery keeps two-factor authentication and blocks factor changes" do
    secret = @account.user.begin_two_factor_setup!(password: "password1234")
    @account.user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    Current.session.mark_two_factor_verified!
    schedule_deletion
    travel 35.seconds do
      post session_path(locale: :en), params: { email_address: @account.user.email_address, password: "password1234" }
      assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
      get account_deletion_path(locale: :en)
      assert_redirected_to challenge_two_factor_authentication_path(locale: :en)
      post verify_two_factor_authentication_path(locale: :en), params: { mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now }
      assert_redirected_to account_deletion_path(locale: :en)
      delete two_factor_authentication_path(locale: :en), params: { current_password: "password1234", mfa_code: "123456" }
      assert_redirected_to account_deletion_path(locale: :en)
      assert @account.user.reload.two_factor_enabled?
      assert @account.user.deletion_pending?
    end
  end

  test "suspension cannot be bypassed through pending recovery" do
    schedule_deletion
    @account.user.update!(suspended_at: Time.current)
    sign_in_as(@account.user)
    get account_deletion_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert_no_difference "Session.count" do
      post session_path(locale: :en), params: { email_address: @account.user.email_address, password: "password1234" }
    end
    assert_redirected_to new_session_path(locale: :en)
    assert @account.user.reload.deletion_pending?
  end

  test "an erased account cannot use pending recovery even if its old password still matches" do
    schedule_deletion
    @account.user.update_columns(erased_at: Time.current)
    assert_no_difference "Session.count" do
      post session_path(locale: :en), params: { email_address: @account.user.email_address, password: "password1234" }
    end
    assert_redirected_to new_session_path(locale: :en)
    get account_deletion_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert_predicate cookies[:session_id], :blank?
  end

  test "password recovery does not cancel pending deletion or regain marketplace access" do
    schedule_deletion
    member = @account.user.reload
    due_at = member.deletion_scheduled_at
    token = member.password_reset_token
    patch password_path(token:, locale: :en), params: { password: "new-password1234", password_confirmation: "new-password1234" }
    assert_redirected_to new_session_path(locale: :en)
    assert member.reload.deletion_pending?
    assert_equal due_at, member.deletion_scheduled_at
    post session_path(locale: :en), params: { email_address: member.email_address, password: "new-password1234" }
    assert_redirected_to account_deletion_path(locale: :en)
    get dashboard_path(locale: :en)
    assert_redirected_to account_deletion_path(locale: :en)
  end

  test "all languages show the grace period and a paused restored request stays cancellable" do
    request = schedule_deletion
    sign_in_as(@account.user.reload)
    %i[nl fr de en].each do |locale|
      get account_deletion_path(locale:)
      assert_response :success
      assert_select "h1", text: I18n.t("account_deletion.pending.heading", locale:)
      assert_select "input[name='current_password'][required]"
      assert_no_match(/translation missing/i, response.body)
    end
    request.update!(finalization_status: "paused")
    get account_deletion_path(locale: :en)
    assert_select "a[href='mailto:support@lawrelay.be']"
    assert_includes response.body, I18n.t("account_deletion.pending.paused", locale: :en)
    assert_select "form[action='#{cancel_account_deletion_path(locale: :en)}']"
  end

  private

  def schedule_deletion
    Accounts::Deletion.schedule!(user: @account.user, current_session: Current.session, password: "password1234")
  end
end
