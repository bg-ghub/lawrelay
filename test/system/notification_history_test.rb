require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class NotificationHistorySystemTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "historybrowser")
    @assignment = create_assignment_for(@account, title: "Notification history browser check")
    @account.user.notifications.create!(kind: "assignment_completed", subject: @assignment, data: { assignment_id: @assignment.id })
    @account.user.notifications.create!(kind: "response_deadline_closed", subject: @assignment,
      data: { assignment_id: @assignment.id }, read_at: Time.current)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    Capybara.reset_sessions!
    @account.user.notifications.delete_all
    @assignment.destroy!
    @account.user.reload.destroy!
    @account.firm.reload.destroy!
  end

  test "a member can browse history filter unread and mark all read on narrow screens" do
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
    click_link "All notifications"
    assert_current_path notifications_path(locale: :en)
    assert_selector ".notification-center-item", count: 2
    assert_text @assignment.title

    page.current_window.resize_to(320, 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    %i[nl fr de en].each do |locale|
      visit notifications_path(locale: locale)
      assert_equal 320, page.evaluate_script("window.innerWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 320
      assert_selector ".notification-center-item", count: 2
      assert_no_text(/translation missing/i)
    end

    click_link "Unread", exact: true
    assert_selector ".notification-center-item", count: 1
    click_button "Mark all read"
    assert_text "You’re up to date"
    assert_selector ".notification-center-item", count: 0
    click_link "All", exact: true
    assert_selector ".notification-center-item", count: 2
    assert_no_selector ".notification-center-unread"
    find(".notification-center-link", match: :first).click
    assert_current_path assignment_path(@assignment, locale: :en)
  end
end
