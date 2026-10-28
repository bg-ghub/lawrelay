require "test_helper"
require_relative "../support/marketplace_test_factory"

class NotificationsIntegrationTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "a user can open and mark only their own notification" do
    owner = create_marketplace_account(prefix: "notification-owner")
    assignment = create_assignment_for(owner)
    notification = owner.user.notifications.create!(
      kind: "new_proposal",
      subject: assignment,
      data: { assignment_id: assignment.id }
    )
    sign_in_as(owner.user)

    get "/fr/notifications/#{notification.id}"

    assert_redirected_to "/fr/assignments/#{assignment.id}"
    assert_not_nil notification.reload.read_at
  end

  test "another verified lawyer cannot mark another user's notification as read" do
    owner = create_marketplace_account(prefix: "notification-owner-protected")
    outsider = create_marketplace_account(prefix: "notification-outsider")
    notification = owner.user.notifications.create!(kind: "new_proposal")
    sign_in_as(outsider.user)

    patch "/en/notifications/#{notification.id}"

    assert_response :not_found
    assert_nil notification.reload.read_at
  end

  test "a user can mark all of their unread notifications read" do
    account = create_marketplace_account(prefix: "mark-all")
    own_notification = account.user.notifications.create!(kind: "new_proposal")
    other_notification = create_marketplace_account(prefix: "mark-all-other").user.notifications.create!(kind: "new_proposal")
    sign_in_as(account.user)

    patch "/nl/notifications/mark_all"

    assert_redirected_to "/nl/dashboard"
    assert_not_nil own_notification.reload.read_at
    assert_nil other_notification.reload.read_at
  end
end
