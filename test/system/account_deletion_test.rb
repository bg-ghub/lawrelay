require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AccountDeletionTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "browser-delete")
    assert_predicate @account.user, :active?
    assert_not_predicate @account.user, :deletion_pending?
  end

  teardown do
    Capybara.reset_sessions!
    remove_account_records
  end

  test "a member schedules deletion and can sign in to cancel it" do
    sign_in
    visit settings_path(locale: :en)
    click_link "Delete account"
    fill_in "current_password", with: "password1234"
    check "confirm_delete_account"
    click_button "Delete account"

    assert_current_path new_session_path(locale: :en)
    assert_text I18n.t("account_deletion.notices.scheduled", locale: :en)
    assert @account.user.reload.deletion_pending?
    assert_nil @account.user.erased_at

    sign_in
    assert_current_path account_deletion_path(locale: :en)
    assert_text I18n.t("account_deletion.pending.heading", locale: :en)
    visit dashboard_path(locale: :en)
    assert_current_path account_deletion_path(locale: :en)
    fill_in "current_password", with: "password1234"
    click_button "Cancel deletion"

    assert_current_path new_session_path(locale: :en)
    assert_text I18n.t("account_deletion.notices.cancelled", locale: :en)
    assert @account.user.reload.active?
    assert_not @account.user.deletion_pending?
    sign_in
    assert_current_path dashboard_path(locale: :en)
  end

  private

  def sign_in
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    click_button "Sign in"
    expected = @account.user.reload.deletion_pending? ? account_deletion_path(locale: :en) : dashboard_path(locale: :en)
    assert_current_path expected
  end

  def remove_account_records
    user_id = @account&.user&.id
    firm_id = @account&.firm&.id
    return unless user_id && firm_id

    request_ids = PrivacyRequest.where(user_id:).pluck(:id)
    deletion_ids = AccountDeletionRequest.where(user_id:).pluck(:id)
    AuditEvent.where(actor_user_id: user_id).or(AuditEvent.where(auditable_type: "User", auditable_id: user_id)).or(
      AuditEvent.where(auditable_type: "PrivacyRequest", auditable_id: request_ids)
    ).or(AuditEvent.where(auditable_type: "AccountDeletionRequest", auditable_id: deletion_ids)).delete_all
    User.where(id: user_id).update_all(deletion_request_id: nil)
    AccountDeletionRequest.where(user_id:).delete_all
    PrivacyRequest.where(user_id:).delete_all
    Notification.where(user_id:).delete_all
    Session.where(user_id:).delete_all
    LawyerProfile.where(user_id:).delete_all
    Membership.where(user_id:).delete_all
    User.where(id: user_id).delete_all
    Firm.where(id: firm_id).delete_all
  end
end
