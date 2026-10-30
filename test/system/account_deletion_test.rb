require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AccountDeletionTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "browser-delete")
    @ledger = Struct.new(:entries) do
      def stage!(user, erased_at:)
        entries << { "user_id" => user.id, "erased_at" => erased_at.utc.iso8601(6) }
        "browser-delete-operation"
      end

      def commit!(_operation) = true
      def abort!(_operation) = entries.clear
    end.new([])
    @original_ledger_constructor = Privacy::ErasureLedger.method(:new)
    ledger = @ledger
    Privacy::ErasureLedger.define_singleton_method(:new) { |*| ledger }
  end

  teardown do
    Capybara.reset_sessions!
    original = @original_ledger_constructor
    Privacy::ErasureLedger.define_singleton_method(:new) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) } if original
    remove_account_records
  end

  test "a member can delete their synthetic account from Profile" do
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    click_button "Sign in"
    assert_current_path dashboard_path(locale: :en)

    visit settings_path(locale: :en)
    click_link "Delete account"
    assert_current_path account_deletion_path(locale: :en)
    fill_in "current_password", with: "password1234"
    check "confirm_delete_account"
    click_button "Delete account"

    assert_current_path root_path(locale: :en)
    assert_text I18n.t("account_deletion.notices.deleted", locale: :en)
    assert_not @account.user.reload.active?
    assert_equal [ @account.user.id ], @ledger.entries.pluck("user_id")

    visit settings_path(locale: :en)
    assert_current_path new_session_path(locale: :en)
  end

  private

  def remove_account_records
    user_id = @account&.user&.id
    firm_id = @account&.firm&.id
    return unless user_id && firm_id

    request_ids = PrivacyRequest.where(user_id:).pluck(:id)
    AuditEvent.where(actor_user_id: user_id).or(AuditEvent.where(auditable_type: "User", auditable_id: user_id)).or(
      AuditEvent.where(auditable_type: "PrivacyRequest", auditable_id: request_ids)
    ).delete_all
    PrivacyRequest.where(user_id:).delete_all
    Notification.where(user_id:).delete_all
    Session.where(user_id:).delete_all
    LawyerProfile.where(user_id:).delete_all
    Membership.where(user_id:).delete_all
    User.where(id: user_id).delete_all
    Firm.where(id: firm_id).delete_all
  end
end
