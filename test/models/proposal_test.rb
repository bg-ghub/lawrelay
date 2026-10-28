require "test_helper"

class ProposalTest < ActiveSupport::TestCase
  def assignment
    Assignment.create!(
      kind: "legal_task", title: "Juridisch advies", description: "Een afgebakende adviesvraag.",
      city: "Gent", starts_at: 3.days.from_now, duration_minutes: 90,
      practice_area: "Handelsrecht", languages: "NL", content_rules_accepted_at: Time.current
    )
  end

  test "accepts a candidate with a valid rate" do
    proposal = assignment.proposals.build(
      name: "Lena Janssens", email: "lena@example.test", rate_cents: 250_00,
      message: "Ik kan dit dossier deze week opnemen."
    )

    assert_predicate proposal, :valid?
  end

  test "rejects an invalid email address" do
    proposal = assignment.proposals.build(
      name: "Lena Janssens", email: "geen-e-mail", rate_cents: 250_00,
      message: "Ik kan dit dossier deze week opnemen."
    )

    assert_not_predicate proposal, :valid?
    assert_includes proposal.errors.attribute_names, :email
  end

  test "accepts fixed and hourly fees but rejects unknown fee types" do
    proposal = assignment.proposals.build(
      name: "Lena Janssens", email: "lena@example.test", rate_cents: 250_00,
      rate_kind: "hourly", message: "Ik kan dit dossier deze week opnemen."
    )
    assert_predicate proposal, :valid?

    proposal.rate_kind = "commission"
    assert_not_predicate proposal, :valid?
    assert_includes proposal.errors.attribute_names, :rate_kind
  end
end
