require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class MarketplaceFlowTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  teardown :remove_system_test_records

  test "signing in preserves the requested locale and destination" do
    account = create_system_account("signin")

    visit new_assignment_path(locale: :fr)

    fill_in "email_address", with: account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click

    assert_current_path new_assignment_path(locale: :fr)
    assert_text "Nouvelle mission"
  end

  test "court cover hides language while a legal task reveals it" do
    account = create_system_account("kind")
    sign_in_through_browser(account.user)

    visit new_assignment_path(locale: :en)

    assert_no_selector "#assignment_languages", visible: :visible
    find("label.kind-option", text: "Legal task").click
    assert_selector "#assignment_languages", visible: :visible
    assert_not find("#assignment_languages").disabled?
    find("label.kind-option", text: "Court cover").click
    assert_no_selector "#assignment_languages", visible: :visible
  end

  test "a verified lawyer can post a safe court-cover assignment" do
    account = create_system_account("post")
    sign_in_through_browser(account.user)

    visit new_assignment_path(locale: :en)
    fill_in "assignment_title", with: "System-test court cover"
    fill_in "assignment_description", with: "A safe summary without client or matter information."
    find("#assignment_practice_area").find("option", text: "Commercial law").select_option
    find("#assignment_court_subtype").find("option[value='hearing']").select_option
    set_datetime("assignment_response_deadline_at", 2.days.from_now)
    set_datetime("assignment_hearing_at", 3.days.from_now)
    fill_in "assignment_duration_minutes", with: "60"
    fill_in "assignment_court", with: "Enterprise Court"
    fill_in "assignment_city", with: "Brussels"
    fill_in "assignment_fee_cents", with: "250"
    find("#assignment_content_rules_accepted").check

    click_button "Post assignment"

    assert_text "System-test court cover"
    assert_equal 1, Assignment.where(title: "System-test court cover").count
  end

  test "an unrelated lawyer is sent back to the board for a closed assignment" do
    owner = create_system_account("closed-owner")
    outsider = create_system_account("closed-outsider")
    assignment = create_assignment_for(owner, title: "Closed private assignment", status: "completed")
    sign_in_through_browser(outsider.user)

    visit assignment_path(assignment, locale: :en)

    assert_current_path assignments_path(locale: :en)
    assert_no_text "Closed private assignment"
  end

  private

  def create_system_account(prefix)
    token = "system-#{prefix}-#{SecureRandom.hex(5)}"
    (@system_test_tokens ||= []) << token
    create_marketplace_account(prefix: token)
  end

  def sign_in_through_browser(user)
    visit new_session_path(locale: :en)
    fill_in "email_address", with: user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  def set_datetime(id, time)
    value = time.strftime("%Y-%m-%dT%H:%M")
    page.execute_script(<<~JAVASCRIPT, id, value)
      const input = document.getElementById(arguments[0]);
      input.value = arguments[1];
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    JAVASCRIPT
  end

  def remove_system_test_records
    tokens = @system_test_tokens || []
    return if tokens.empty?

    users = User.where(tokens.map { |token| "email_address LIKE ?" }.join(" OR "), *tokens.map { |token| "#{token}%" })
    user_ids = users.pluck(:id)
    firm_ids = Membership.where(user_id: user_ids).pluck(:firm_id)
    assignment_ids = Assignment.where(firm_id: firm_ids).pluck(:id)

    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Notification.where(user_id: user_ids).delete_all
    Proposal.where(user_id: user_ids).or(Proposal.where(assignment_id: assignment_ids)).delete_all
    Assignment.where(id: assignment_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: firm_ids).delete_all
  end
end
