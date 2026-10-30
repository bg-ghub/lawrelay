require "test_helper"

class AssignmentTest < ActiveSupport::TestCase
  def valid_attributes
    {
      kind: "court_replacement", title: "Verschijning ondernemingsrechtbank",
      description: "Een korte, heldere omschrijving van de opdracht.", court: "Ondernemingsrechtbank Antwerpen", city: "Antwerpen",
      starts_at: 2.days.from_now, duration_minutes: 60, practice_area: "Handelsrecht", languages: "NL",
      content_rules_accepted_at: Time.current
    }
  end

  test "accepts a complete assignment" do
    assignment = Assignment.new(valid_attributes)

    assert_predicate assignment, :valid?
    assert assignment.court_replacement?
    assert_equal "Zittingsvervanging", assignment.kind_label
  end

  test "requires the core matching details" do
    assignment = Assignment.new(valid_attributes.merge(title: nil, city: nil))

    assert_not_predicate assignment, :valid?
    assert_includes assignment.errors.attribute_names, :title
    assert_includes assignment.errors.attribute_names, :city
  end

  test "requires confirmation that confidential matter data was excluded" do
    assignment = Assignment.new(valid_attributes.merge(content_rules_accepted_at: nil))

    assert_not_predicate assignment, :valid?
    assert_includes assignment.errors.full_messages, I18n.t("workflow.errors.content_rules_required")
  end

  test "does not require languages for court replacements" do
    assignment = Assignment.new(valid_attributes.merge(languages: nil))

    assert_predicate assignment, :valid?
  end

  test "discards languages for court replacements" do
    assignment = Assignment.create!(valid_attributes.merge(languages: "NL, FR"))

    assert_nil assignment.languages
  end

  test "requires languages for legal tasks" do
    assignment = Assignment.new(valid_attributes.merge(kind: "legal_task", languages: nil))

    assert_not_predicate assignment, :valid?
    assert_includes assignment.errors.attribute_names, :languages
  end

  test "allows a remote legal task without a court or city" do
    execution_deadline = 4.days.from_now
    assignment = Assignment.new(
      valid_attributes.merge(
        kind: "legal_task",
        assignment_subtype: "advice",
        languages: "NL",
        city: nil,
        court: nil,
        starts_at: execution_deadline,
        response_deadline_at: 2.days.from_now,
        delivery_due_at: 3.days.from_now,
        duration_minutes: nil
      )
    )

    assert_predicate assignment, :valid?
  end

  test "requires a court and city for court cover" do
    assignment = Assignment.new(valid_attributes.merge(court: nil, city: nil))

    assert_not_predicate assignment, :valid?
    assert_includes assignment.errors.attribute_names, :court
    assert_includes assignment.errors.attribute_names, :city
  end

  test "rejects invalid subtype and deadline sequences" do
    assignment = Assignment.new(
      valid_attributes.merge(
        assignment_subtype: "contract",
        response_deadline_at: 3.days.from_now,
        starts_at: 2.days.from_now
      )
    )

    assert_not_predicate assignment, :valid?
    assert_includes assignment.errors.attribute_names, :assignment_subtype
    assert_includes assignment.errors.attribute_names, :response_deadline_at
  end

  test "sets a safe response deadline for legacy server-side creation" do
    assignment = Assignment.create!(valid_attributes)

    assert_equal assignment.starts_at - 1.hour, assignment.response_deadline_at
    assert_equal "hearing", assignment.assignment_subtype
  end

  test "requires legal delivery after the response deadline and before execution" do
    assignment = Assignment.new(
      valid_attributes.merge(
        kind: "legal_task",
        assignment_subtype: "advice",
        languages: "NL",
        city: nil,
        starts_at: 4.days.from_now,
        response_deadline_at: 3.days.from_now,
        delivery_due_at: 2.days.from_now
      )
    )

    assert_not_predicate assignment, :valid?
    assert_includes assignment.errors.attribute_names, :delivery_due_at
  end

  test "search escapes wildcard input" do
    assignment = Assignment.create!(valid_attributes.merge(title: "Hoorzitting in Gent"))

    assert_equal [ assignment ], Assignment.search("Gent").to_a
    assert_empty Assignment.search("%_").to_a
  end

  test "translates assignment kinds in every supported locale" do
    assignment = Assignment.new(valid_attributes)

    {
      nl: "Zittingsvervanging",
      fr: "Remplacement d’audience",
      de: "Vertretung bei Gericht",
      en: "Court replacement"
    }.each do |locale, label|
      I18n.with_locale(locale) { assert_equal label, assignment.kind_label }
    end
  end

  test "invoice defaults copy KBO attribution without sharing the firm hash" do
    details = {
      "snapshot_date" => "2026-10-15",
      "fields" => [ "name", "enterprise_number", "address_line_1" ]
    }
    firm = Firm.new(name: "KBO recipient", enterprise_number: "1234567894", kbo_details: details)
    user = User.new(email_address: "invoice-default@example.test")

    defaults = Assignment.default_invoice_recipient(firm:, user:)
    defaults.fetch(:invoice_kbo_details).fetch("fields") << "city"

    assert_equal "2026-10-15", defaults.dig(:invoice_kbo_details, "snapshot_date")
    assert_equal [ "name", "enterprise_number", "address_line_1" ], firm.kbo_details.fetch("fields")
  end
end
