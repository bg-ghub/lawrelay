require "test_helper"
require_relative "../support/marketplace_test_factory"

class AssignmentInvoiceRecipientTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "new assignment forms collect only assignment details in every language" do
    owner = create_marketplace_account(prefix: "invoicedefault")
    owner.firm.update!(billing_email: "invoices@example.test", address_line_1: "Practice Street 10", postal_code: "1000", city: "Brussels")
    sign_in_as(owner.user)

    %i[nl fr de en].each do |locale|
      get new_assignment_path(locale:)

      assert_response :success
      assert_select "input[name^='assignment[invoice_']", count: 0
      assert_select "input[name='assignment[kbo_lookup_token]']", count: 0
      assert_select "[data-controller~='business-lookup']", count: 0
      assert_select "[data-controller~='company-number']", count: 0
      assert_select "#assignment_court_subtype", count: 0
      assert_select ".field-hint", text: I18n.t("company_minimization.private_invoice_details", locale:)
      assert_not_includes response.body, owner.firm.name
      assert_not_includes response.body, "invoices@example.test"
      assert_not_includes response.body, "Practice Street 10"
    end
  end

  test "an assignment can be posted without an invoice recipient or a fee" do
    owner = create_marketplace_account(prefix: "minimalassignment")
    sign_in_as(owner.user)

    assert_difference "Assignment.count", 1 do
      post assignments_path(locale: :en), params: { assignment: assignment_attributes }
    end

    assignment = Assignment.order(:id).last
    assert_redirected_to assignment_path(assignment, locale: :en)
    assert_equal owner.firm, assignment.firm
    assert_equal owner.user, assignment.creator_user
    assert_nil assignment.fee_cents
    assert_nil assignment.assignment_subtype
    assert_empty assignment.attributes.select { |key, _| key.start_with?("invoice_") }.values.compact_blank
  end

  test "old invoice fields and lookup metadata cannot be stored or change ownership" do
    owner = create_marketplace_account(prefix: "invoiceowner")
    outsider = create_marketplace_account(prefix: "invoiceoutsider")
    original_firm = owner.firm.attributes
    sign_in_as(owner.user)

    assert_difference "Assignment.count", 1 do
      post assignments_path(locale: :en), params: {
        assignment: assignment_attributes.merge(invoice_attributes).merge(
          firm_id: outsider.firm.id, creator_user_id: outsider.user.id, assignment_subtype: "hearing",
          invoice_vat_number: "BE9999999999", invoice_kbo_details: { snapshot_date: "2026-10-29", fields: [ "name" ] },
          kbo_lookup_token: "retired-lookup-token", kbo_details: { snapshot_date: "2026-10-29" }
        )
      }
    end

    assignment = Assignment.order(:id).last
    assert_redirected_to assignment_path(assignment, locale: :en)
    assert_equal owner.firm, assignment.firm
    assert_equal owner.user, assignment.creator_user
    assert_nil assignment.assignment_subtype
    assert_empty assignment.attributes.select { |key, _| key.start_with?("invoice_") }.values.compact_blank
    assert_equal original_firm, owner.firm.reload.attributes
  end

  test "content and future deadline safeguards still apply without invoice details" do
    owner = create_marketplace_account(prefix: "invoicevalidation")
    sign_in_as(owner.user)

    assert_no_difference "Assignment.count" do
      post assignments_path(locale: :en), params: {
        assignment: assignment_attributes.merge(content_rules_accepted: "0", starts_at: 2.hours.ago)
      }
    end

    assert_response :unprocessable_content
    assert_select ".form-error", text: /#{Regexp.escape(I18n.t("workflow.errors.content_rules_required", locale: :en))}/
    assert_select ".form-error", text: /must be in the future/
    assert_select "input[name^='assignment[invoice_']", count: 0
  end

  test "only accepted counterparts exchange account email and legacy billing stays hidden" do
    owner = create_marketplace_account(prefix: "privateinvoiceowner")
    candidate = create_marketplace_account(prefix: "privateinvoicecandidate")
    other = create_marketplace_account(prefix: "privateinvoiceother")
    outsider = create_marketplace_account(prefix: "privateinvoiceoutsider")
    assignment = create_assignment_for(owner)
    assignment.update!(invoice_attributes)
    accepted = create_proposal_for(assignment, candidate)
    create_proposal_for(assignment, other)

    [ owner, candidate, other ].each do |account|
      sign_in_as(account.user)
      get assignment_path(assignment, locale: :en)
      assert_response :success
      assert_select ".contact-card", count: 0
      assert_legacy_invoice_hidden
    end

    sign_in_as(owner.user)
    patch accept_assignment_proposal_path(assignment, accepted, locale: :en)
    assert_equal "accepted", accepted.reload.status
    assert_equal "matched", assignment.reload.status
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:#{candidate.user.email_address}']"
    assert_select ".contact-card a[href='mailto:#{other.user.email_address}']", count: 0
    assert_legacy_invoice_hidden

    sign_in_as(candidate.user)
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:#{owner.user.email_address}']"
    assert_legacy_invoice_hidden

    sign_in_as(other.user)
    get assignment_path(assignment, locale: :en)
    assert_response :success
    assert_select ".contact-card", count: 0
    assert_legacy_invoice_hidden

    sign_in_as(outsider.user)
    get assignment_path(assignment, locale: :en)
    assert_redirected_to assignments_path(locale: :en)

    assignment.complete!(actor: owner.user)
    sign_in_as(candidate.user)
    get assignment_path(assignment, locale: :en)
    assert_select ".contact-card a[href='mailto:#{owner.user.email_address}']"
    assert_legacy_invoice_hidden
  end

  test "assignments still complete without an invoice snapshot" do
    owner = create_marketplace_account(prefix: "legacyinvoiceowner")
    assignment = create_assignment_for(owner, status: "matched")
    sign_in_as(owner.user)

    get assignment_path(assignment, locale: :en)
    assert_select ".field-hint", text: I18n.t("company_minimization.private_invoice_details", locale: :en)
    patch complete_assignment_path(assignment, locale: :en)
    assert_equal "completed", assignment.reload.status
  end

  private

  def assert_legacy_invoice_hidden
    assert_select ".assignment-invoice-recipient", count: 0
    invoice_attributes.values.each { |value| assert_not_includes response.body, value }
  end

  def invoice_attributes
    {
      invoice_name: "Recipient Practice", invoice_enterprise_number: "1234567894",
      invoice_email: "recipient@example.test", invoice_address_line_1: "Recipient Street 12",
      invoice_postal_code: "9876", invoice_city: "Synthetic Billing City"
    }
  end

  def assignment_attributes
    {
      kind: "court_replacement", title: "Court cover without billing data",
      description: "A bounded assignment without case details.", court: "Enterprise Court", city: "Brussels",
      starts_at: 3.days.from_now, response_deadline_at: 2.days.from_now,
      duration_minutes: 60, practice_area: "Commercial law", content_rules_accepted: "1"
    }
  end
end
