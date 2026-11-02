require "test_helper"
require_relative "../support/marketplace_test_factory"

class AdminDeletionStatusTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  self.fixture_table_names = []

  setup do
    @admin = create_marketplace_account(prefix: "status-admin", system_role: "admin").user
    @active = create_marketplace_account(prefix: "status-member-active").user
    @pending = create_marketplace_account(prefix: "status-member-pending").user
    @partial = create_marketplace_account(prefix: "status-member-partial").user
    @suspended = create_marketplace_account(prefix: "status-member-suspended").user
    @erased = create_marketplace_account(prefix: "status-member-erased").user

    requested_at = Time.current
    request = @pending.account_deletion_requests.create!(requested_at:, scheduled_at: requested_at + 30.days)
    @pending.update!(deletion_request: request, deletion_requested_at: request.requested_at, deletion_scheduled_at: request.scheduled_at)
    @partial.update!(deletion_requested_at: requested_at)
    @suspended.update!(suspended_at: requested_at)
    @erased.update_columns(erased_at: requested_at)
    sign_in_as(@admin, admin_mfa: true)
  end

  test "pending deletion is labelled in each language and its date appears only in details" do
    %w[nl fr de en].each do |locale|
      get admin_users_path(locale:), params: { q: "status-member-pending" }
      assert_response :success
      assert_select ".admin-user-row", count: 1
      assert_select ".status-pill.admin-user-status--suspended", text: I18n.t("admin.users.status.deletion_pending", locale:)
      assert_select ".admin-user-row time", count: 0
      assert_select "option[value='deletion_pending']", text: I18n.t("admin.users.status.deletion_pending", locale:)

      get admin_user_path(@pending, locale:)
      assert_response :success
      assert_select ".admin-user-overview .status-pill", text: I18n.t("admin.users.status.deletion_pending", locale:)
      assert_select ".admin-user-overview dt", text: I18n.t("admin.users.fields.deletion_scheduled_at", locale:)
      assert_select ".admin-user-overview time[datetime='#{@pending.deletion_scheduled_at.iso8601}']",
        text: @pending.deletion_scheduled_at.in_time_zone("Europe/Brussels").strftime("%d/%m/%Y")
      assert_select ".admin-user-overview dd", text: I18n.t("admin.users.marketplace.unavailable", locale:)
      assert_no_match(/translation missing/i, response.body)
    end
  end

  test "active filter excludes pending deletion partial markers suspended and erased accounts" do
    assert_filtered_accounts "active", [ @active ]
  end

  test "pending deletion filter and count include partial markers without describing them as active" do
    assert_filtered_accounts "deletion_pending", [ @pending, @partial ]
    assert_select ".admin-user-row .status-pill", text: I18n.t("admin.users.status.deletion_pending", locale: :en), count: 2
    assert_select ".admin-user-row .status-pill", text: I18n.t("admin.users.status.active", locale: :en), count: 0
  end

  test "suspended filter excludes deletion requests and erased records" do
    assert_filtered_accounts "suspended", [ @suspended ]
  end

  test "pending deletion keeps priority over suspension without changing access controls" do
    @pending.update!(suspended_at: Time.current)
    assert_filtered_accounts "deletion_pending", [ @pending, @partial ]
    assert_filtered_accounts "suspended", [ @suspended ]
    assert_not @pending.reload.active?
    assert_not @pending.marketplace_verified?
  end

  test "erased accounts are absent from the overview search verification filters and totals" do
    assert_filtered_accounts "", [ @active, @pending, @partial, @suspended ]

    [ {}, { verification: "verified" }, { verification: "pending" }, { status: "suspended" } ].each do |filters|
      get admin_users_path(locale: :en), params: filters.merge(q: @erased.email_address)
      assert_response :success
      assert_select ".admin-user-row", count: 0
      assert_select ".admin-users-total", text: I18n.t("admin.users.index.total", count: 0, locale: :en)
    end
    assert User.exists?(@erased.id), "The erased identity must remain available to protected internal references"
  end

  test "erased accounts cannot be opened or changed through old admin links" do
    original = @erased.reload.attributes
    assert_no_difference "AuditEvent.count" do
      [ @erased.public_id, @erased.id ].each do |identifier|
        get admin_user_path(identifier, locale: :en)
        assert_response :not_found
        patch admin_user_path(identifier, locale: :en), params: { user: { first_name: "Revived" } }
        assert_response :not_found
        %w[suspend restore revoke_sessions].each do |action|
          patch public_send("#{action}_admin_user_path", identifier, locale: :en), params: { user_management: { reason: "Old bookmark" } }
          assert_response :not_found
        end
        post resend_verification_admin_user_path(identifier, locale: :en)
        assert_response :not_found
      end
    end
    assert_equal original, @erased.reload.attributes
  end

  private

  def assert_filtered_accounts(status, expected)
    get admin_users_path(locale: :en), params: { q: "status-member-", status: }
    assert_response :success
    assert_select ".admin-user-row", count: expected.size
    assert_select ".admin-users-total", text: I18n.t("admin.users.index.total", count: expected.size, locale: :en)
    [ @active, @pending, @partial, @suspended, @erased ].each do |user|
      assert_select ".admin-user-row a[href='#{admin_user_path(user, locale: :en)}']", count: expected.include?(user) ? 2 : 0
    end
  end
end
