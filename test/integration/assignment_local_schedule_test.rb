require "test_helper"
require_relative "../support/marketplace_test_factory"

class AssignmentLocalScheduleTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "local-schedule")
    sign_in_as(@owner.user)
    @attributes = { kind: "legal_task", assignment_subtype: "advice", title: "Synthetic legal task",
      description: "No client details.", practice_area: "Burgerlijk recht", languages: "NL",
      content_rules_accepted: "1" }
  end

  test "typed schedule is interpreted as Brussels local time" do
    travel_to Time.zone.local(2026, 6, 1, 9) do
      assert_difference "Assignment.count", 1 do
        post assignments_path(locale: :nl), params: { assignment: @attributes.merge(local_schedule: {
          response_deadline_at: "3/6/2026 09:30", delivery_due_at: "04/06/2026 11:30", starts_at: "05/06/2026 14:45"
        }) }
      end
    end

    assignment = @owner.firm.assignments.sole
    assert_redirected_to assignment_path(assignment, locale: :nl)
    assert_equal Time.utc(2026, 6, 3, 7, 30), assignment.response_deadline_at.utc
    assert_equal Time.utc(2026, 6, 4, 9, 30), assignment.delivery_due_at.utc
    assert_equal Time.utc(2026, 6, 5, 12, 45), assignment.starts_at.utc
  end

  test "invalid optional date is rejected and redisplayed" do
    travel_to Time.zone.local(2026, 6, 1, 9) do
      assert_no_difference "Assignment.count" do
        post assignments_path(locale: :nl), params: { assignment: @attributes.merge(local_schedule: {
          response_deadline_at: "03/06/2026 09:30", delivery_due_at: "31/06/2026 11:30", starts_at: "05/06/2026 14:45"
        }) }
      end
    end

    assert_response :unprocessable_content
    assert_select "#assignment_delivery_due_at[value='31/06/2026 11:30']"
    assert_select "#assignment_execution_deadline[value='05/06/2026 14:45']"
    assert_select "#assignment_hearing_at[disabled]"
    assert_includes response.body, I18n.t("marketplace.form.datetime_invalid", locale: :nl)
  end

  test "a blank typed response deadline does not get a default" do
    assert_no_difference "Assignment.count" do
      post assignments_path(locale: :nl), params: { assignment: @attributes.merge(local_schedule: {
        response_deadline_at: "   ", delivery_due_at: "", starts_at: 3.days.from_now.strftime("%d/%m/%Y %H:%M")
      }) }
    end

    assert_response :unprocessable_content
    assert_includes response.body, I18n.t("marketplace.form.datetime_invalid", locale: :nl)
  end
end
