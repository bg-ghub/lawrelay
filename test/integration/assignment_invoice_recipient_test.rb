require "test_helper"
require_relative "../support/marketplace_test_factory"

class AssignmentInvoiceRecipientTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "new form defaults to the saved recipient without binding the assignment to that company" do
    owner = create_marketplace_account(prefix: "invoicedefault")
    owner.firm.update!(billing_email: "invoices@example.test", address_line_1: "Practice Street 10", postal_code: "1000", city: "Brussels")
    sign_in_as(owner.user)

    get new_assignment_path(locale: :en)

    assert_response :success
    assert_select "input[name='assignment[invoice_name]'][value='#{owner.firm.name}'][required]"
    assert_select "input[name='assignment[invoice_enterprise_number]'][value='#{owner.firm.enterprise_number}'][required]"
    assert_select "input[name='assignment[invoice_email]'][value='invoices@example.test'][required]"
    assert_select "input[name='assignment[invoice_address_line_1]'][value='Practice Street 10'][required]"
    assert_select "#assignment_invoice_vat_number[readonly]:not([name])"
  end

  test "each assignment saves its own recipient and ignores forged ownership and vat fields" do
    owner = create_marketplace_account(prefix: "invoiceowner")
    outsider = create_marketplace_account(prefix: "invoiceoutsider")
    sign_in_as(owner.user)

    assert_difference "Assignment.count", 1 do
      post assignments_path(locale: :en), params: {
        assignment: assignment_attributes.merge(
          firm_id: outsider.firm.id, creator_user_id: outsider.user.id,
          invoice_vat_number: "BE9999999999"
        )
      }
    end

    assignment = Assignment.order(:id).last
    assert_redirected_to assignment_path(assignment, locale: :en)
    assert_equal owner.firm, assignment.firm
    assert_equal owner.user, assignment.creator_user
    assert_equal "Recipient Practice", assignment.invoice_name
    assert_equal "1234567894", assignment.invoice_enterprise_number
    assert_equal "BE1234567894", assignment.invoice_vat_number
    assert_equal "recipient@example.test", assignment.invoice_email

    owner.firm.update!(name: "Changed saved recipient", enterprise_number: "0000000097", billing_email: "changed@example.test", address_line_1: "Another street 1")
    assignment.reload
    assert_equal "Recipient Practice", assignment.invoice_name
    assert_equal "1234567894", assignment.invoice_enterprise_number
    assert_equal "Recipient Street 12", assignment.invoice_address_line_1
    assert_equal "recipient@example.test", assignment.invoice_email
  end

  test "blank invoice details are rejected and other create safeguards still run" do
    owner = create_marketplace_account(prefix: "invoicevalidation")
    sign_in_as(owner.user)

    assert_no_difference "Assignment.count" do
      post assignments_path(locale: :en), params: {
        assignment: assignment_attributes.merge(invoice_name: "", invoice_enterprise_number: "", content_rules_accepted: "0", starts_at: 2.hours.ago)
      }
    end

    assert_response :unprocessable_content
    assert_select ".form-error", text: /Invoice recipient/
    assert_select ".form-error", text: /#{Regexp.escape(I18n.t("workflow.errors.content_rules_required", locale: :en))}/
    assert_select ".form-error", text: /must be in the future/
  end

  test "an invalid enterprise number is rejected on the server" do
    owner = create_marketplace_account(prefix: "invalidinvoicenumber")
    sign_in_as(owner.user)

    %w[1234567890 12345678940 BEfoo].each do |number|
      assert_no_difference "Assignment.count" do
        post assignments_path(locale: :en), params: { assignment: assignment_attributes.merge(invoice_enterprise_number: number) }
      end
      assert_response :unprocessable_content
      assert_select ".form-error", text: /Enterprise number/
    end
  end

  test "only owner and accepted confrater see full invoice details" do
    owner = create_marketplace_account(prefix: "privateinvoiceowner")
    candidate = create_marketplace_account(prefix: "privateinvoicecandidate")
    other = create_marketplace_account(prefix: "privateinvoiceother")
    assignment = create_assignment_for(owner)
    assignment.update!(invoice_attributes)
    accepted = create_proposal_for(assignment, candidate)
    create_proposal_for(assignment, other)

    sign_in_as(other.user)
    get assignment_path(assignment, locale: :en)
    assert_response :success
    assert_select ".assignment-invoice-recipient", text: /Recipient Practice/
    assert_select ".assignment-invoice-recipient", text: /1234567894/
    assert_not_includes response.body, "recipient@example.test"
    assert_not_includes response.body, "Recipient Street 12"

    sign_in_as(owner.user)
    get assignment_path(assignment, locale: :en)
    assert_select ".assignment-invoice-recipient a[href='mailto:recipient@example.test']"
    assert_includes response.body, "Recipient Street 12"
    patch accept_assignment_proposal_path(assignment, accepted, locale: :en)
    assert_equal "accepted", accepted.reload.status

    sign_in_as(candidate.user)
    get assignment_path(assignment, locale: :en)
    assert_select ".assignment-invoice-recipient a[href='mailto:recipient@example.test']"
    assert_includes response.body, "Recipient Street 12"

    assignment.complete!(actor: owner.user)
    get assignment_path(assignment, locale: :en)
    assert_select ".assignment-invoice-recipient a[href='mailto:recipient@example.test']"

    sign_in_as(other.user)
    get assignment_path(assignment, locale: :en)
    assert_response :success
    assert_not_includes response.body, "recipient@example.test"
    assert_not_includes response.body, "Recipient Street 12"
  end

  test "legacy assignments still complete without an invoice snapshot" do
    owner = create_marketplace_account(prefix: "legacyinvoiceowner")
    assignment = create_assignment_for(owner, status: "matched")
    assert_nil assignment.invoice_name
    sign_in_as(owner.user)

    get assignment_path(assignment, locale: :en)
    assert_select ".assignment-invoice-recipient", text: /Agree the billing details/
    patch complete_assignment_path(assignment, locale: :en)
    assert_equal "completed", assignment.reload.status
  end

  private

  def invoice_attributes
    {
      invoice_name: "Recipient Practice", invoice_enterprise_number: "BE 1234.567.894",
      invoice_email: "recipient@example.test", invoice_address_line_1: "Recipient Street 12",
      invoice_postal_code: "1000", invoice_city: "Brussels"
    }
  end

  def assignment_attributes
    {
      kind: "court_replacement", title: "Recipient-specific court cover",
      description: "A bounded assignment without case details.", court: "Enterprise Court", city: "Brussels",
      starts_at: 3.days.from_now, response_deadline_at: 2.days.from_now,
      duration_minutes: 60, practice_area: "Commercial law", content_rules_accepted: "1"
    }.merge(invoice_attributes)
  end
end
