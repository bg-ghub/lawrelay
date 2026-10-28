require "test_helper"

class ParameterFilterTest < ActiveSupport::TestCase
  test "filters authentication codes and professional free text in nested request parameters" do
    payload = {
      "mfa_code" => "123456",
      "report" => { "details" => "synthetic confidential report", "resolution_note" => "synthetic resolution" },
      "verification" => { "note" => "synthetic verification note" },
      "assignment" => { "title" => "synthetic assignment title", "scope_indication" => "synthetic scope", "kind" => "legal_assignment" },
      "profile" => { "availability_note" => "synthetic availability" }
    }

    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(payload)

    assert_equal "[FILTERED]", filtered.fetch("mfa_code")
    %w[details resolution_note].each { |key| assert_equal "[FILTERED]", filtered.fetch("report").fetch(key) }
    assert_equal "[FILTERED]", filtered.fetch("verification").fetch("note")
    %w[title scope_indication].each { |key| assert_equal "[FILTERED]", filtered.fetch("assignment").fetch(key) }
    assert_equal "[FILTERED]", filtered.fetch("profile").fetch("availability_note")
    assert_equal "legal_assignment", filtered.fetch("assignment").fetch("kind")
  end
end
