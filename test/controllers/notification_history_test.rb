require "test_helper"
require_relative "../support/marketplace_test_factory"

class NotificationHistoryTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "historymember")
    @other = create_marketplace_account(prefix: "historyother")
    @assignment = create_assignment_for(@account, title: "Own notification history")
    @other_assignment = create_assignment_for(@other, title: "Private other assignment", status: "cancelled")
    @other_notification = @other.user.notifications.create!(kind: "assignment_cancelled", subject: @other_assignment)
    sign_in_as(@account.user)
  end

  test "history is owner scoped paginated bounded and does not mark records read" do
    notifications = Array.new(30) do |index|
      @account.user.notifications.create!(kind: "assignment_completed", subject: @assignment,
        read_at: (Time.current if index.even?), created_at: index.minutes.ago)
    end

    get notifications_path(locale: :en), params: { user_id: @other.user.id, per_page: 100_000 }
    assert_response :success
    assert_select ".notification-center-item", count: 25
    assert_select "a[href='#{notification_path(notifications.last, locale: :en)}']", count: 0
    assert_select "a[href='#{notification_path(@other_notification, locale: :en)}']", count: 0
    assert_not_includes response.body, @other_assignment.title
    assert_select ".notification-center-pagination", count: 1
    assert_equal 15, @account.user.notifications.unread.count

    get notifications_path(locale: :en), params: { page: 2 }
    assert_select ".notification-center-item", count: 5
    assert_select "a[href='#{notification_path(notifications.last, locale: :en)}']", count: 1
    get notifications_path(locale: :en), params: { page: -20 }
    assert_select ".notification-center-item", count: 25
    get notifications_path(locale: :en), params: { page: 100_000 }
    assert_select ".notification-center-item", count: 5
  end

  test "unread filter and bulk read affect only the signed in member" do
    @account.user.notifications.create!(kind: "new_proposal", subject: @assignment)
    @account.user.notifications.create!(kind: "assignment_completed", subject: @assignment, read_at: Time.current)
    get notifications_path(locale: :en), params: { filter: "unread" }
    assert_response :success
    assert_select ".notification-center-item", count: 1
    assert_select ".notification-center-unread", count: 1

    patch mark_all_notifications_path(locale: :en), params: { from: "notifications", filter: "unread" }
    assert_redirected_to notifications_path(locale: :en, filter: "unread")
    follow_redirect!
    assert_select ".notification-center-item", count: 0
    assert_includes response.body, I18n.t("notification_center.caught_up", locale: :en)
    assert_empty @account.user.notifications.unread
    assert_nil @other_notification.reload.read_at

    patch mark_all_notifications_path(locale: :en), params: { from: "https://outside.example" }
    assert_redirected_to dashboard_path(locale: :en)
  end

  test "history never exposes an unavailable closed assignment title or delivery metadata" do
    own_record = @account.user.notifications.create!(kind: "assignment_cancelled", subject: @other_assignment,
      data: { assignment_id: @other_assignment.id })
    get notifications_path(locale: :en)
    assert_response :success
    assert_not_includes response.body, @other_assignment.title
    assert_select ".notification-center-copy strong", text: I18n.t("notification_center.unavailable", locale: :en)
    assert_not_includes response.body, "email_status"

    get notification_path(own_record, locale: :en)
    assert_redirected_to dashboard_path(locale: :en)
    assert_not_nil own_record.reload.read_at
  end

  test "history requires authentication and professional verification" do
    sign_out
    get notifications_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    @account.profile.update!(verification_status: "pending", verified_at: nil)
    sign_in_as(@account.user)
    get notifications_path(locale: :en)
    assert_redirected_to verification_status_path(locale: :en)
  end

  test "history and empty dashboard links render in every interface language" do
    %i[nl fr de en].each do |locale|
      get notifications_path(locale: locale)
      assert_response :success
      assert_select "html[lang='#{locale}']"
      assert_select "h1", text: I18n.t("workflow.ui.notifications", locale: locale)
      assert_not_includes response.body, "translation missing"
      get dashboard_path(locale: locale)
      assert_response :success
      assert_select "a[href='#{notifications_path(locale: locale)}']", text: I18n.t("notification_center.all_notifications", locale: locale)
    end
  end

  test "pending proposals for closed assignments show closure without rewriting proposal state" do
    @other_assignment.update!(status: "open")
    proposal = create_proposal_for(@other_assignment, @account)
    %w[cancelled expired].each do |status|
      @other_assignment.update!(status: status)
      get dashboard_path(locale: :en)
      assert_response :success
      assert_select ".proposal-preview p", text: /#{Regexp.escape(I18n.t("marketplace.status.#{status}", locale: :en))}/
      assert_select ".proposal-preview p", text: /#{Regexp.escape(I18n.t("marketplace.status.pending", locale: :en))}/, count: 0
      assert_equal "pending", proposal.reload.status
    end
  end
end
