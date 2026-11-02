require "test_helper"

class ProposalTest < ActiveSupport::TestCase
  def assignment
    Assignment.create!(
      kind: "legal_task", assignment_subtype: "advice", title: "Juridisch advies", description: "Een afgebakende adviesvraag.",
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

  test "separate travel costs are required and stored as nonnegative integer cents" do
    proposal = court_proposal(travel_included: false)
    assert_not_predicate proposal, :valid?
    assert_includes proposal.errors.attribute_names, :travel_cost_cents

    [ nil, -1, "12.5", "NaN", "Infinity", Proposal::MAX_RATE_CENTS + 1 ].each do |amount|
      proposal.travel_cost_cents = amount
      assert_not_predicate proposal, :valid?, "Unexpected valid travel amount #{amount.inspect}"
    end
    [ 0, 2_450, Proposal::MAX_RATE_CENTS ].each do |amount|
      proposal.travel_cost_cents = amount
      assert_predicate proposal, :valid?
    end
    proposal.travel_cost_cents = 2_450
    proposal.save!
    assert_equal false, proposal.reload.travel_included
    assert_equal 2_450, proposal.travel_cost_cents
    assert_equal "fixed", proposal.travel_cost_kind
    assert_predicate proposal, :valid?
  end

  test "separate travel can store a fixed amount or a per kilometre rate" do
    Proposal::TRAVEL_COST_KINDS.each do |kind|
      proposal = court_proposal(travel_included: false, travel_cost_kind: kind, travel_cost_cents: 45)
      proposal.save!
      assert_equal kind, proposal.reload.travel_cost_kind
      assert_equal 45, proposal.travel_cost_cents
    end
  end

  test "unknown or blank separate travel pricing kinds are rejected" do
    [ "", "hourly", "per_mile", "FIXED" ].each do |kind|
      proposal = court_proposal(travel_included: false, travel_cost_kind: kind, travel_cost_cents: 45)
      assert_not_predicate proposal, :valid?
      assert_includes proposal.errors.attribute_names, :travel_cost_kind
    end
  end

  test "included or unspecified travel never retains an additional charge" do
    [ true, nil ].each do |included|
      proposal = court_proposal(travel_included: included, travel_cost_cents: 2_500, travel_cost_kind: "per_km")
      assert_predicate proposal, :valid?
      assert_nil proposal.travel_cost_cents
      assert_nil proposal.travel_cost_kind
      proposal.save!
      if included.nil?
        assert_nil proposal.reload.travel_included
      else
        assert_equal true, proposal.reload.travel_included
      end
      proposal.update!(status: "declined")
      if included.nil?
        assert_nil proposal.reload.travel_included
      else
        assert_equal true, proposal.reload.travel_included
      end
      assert_nil proposal.travel_cost_cents
      assert_nil proposal.travel_cost_kind
    end
  end

  test "unknown travel choices are rejected instead of silently interpreted as included" do
    proposal = court_proposal(travel_included: "unknown")
    assert_not_predicate proposal, :valid?
    assert_includes proposal.errors.attribute_names, :travel_included
    [ true, false, "true", "false", "1", "0" ].each do |choice|
      proposal.assign_attributes(travel_included: choice, travel_cost_cents: 0)
      assert_predicate proposal, :valid?
    end
  end

  test "legal tasks ignore stale travel fields" do
    proposal = assignment.proposals.build(name: "Lena Janssens", email: "lena@example.test", rate_cents: 250_00,
      message: "A bounded legal task.", travel_included: false, travel_cost_cents: "invalid", travel_cost_kind: "invalid")
    assert_predicate proposal, :valid?
    assert_nil proposal.travel_included
    assert_nil proposal.travel_cost_cents
    assert_nil proposal.travel_cost_kind
  end

  private

  def court_proposal(**attributes)
    task = assignment
    task.update!(kind: "court_replacement", assignment_subtype: nil, court: "Enterprise Court", city: "Brussels")
    task.proposals.build(name: "Lena Janssens", email: "lena@example.test", rate_cents: 250_00,
      message: "A bounded court appearance.", **attributes)
  end
end
