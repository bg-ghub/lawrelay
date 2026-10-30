module MarketplaceTestFactory
  Account = Data.define(:user, :firm, :profile)

  def create_marketplace_account(prefix:, verified: true, email_verified: true, system_role: "member")
    token = "#{prefix}-#{SecureRandom.hex(4)}"
    enterprise_base = SecureRandom.random_number(90_000_000) + 10_000_000
    enterprise_number = format("%08d%02d", enterprise_base, 97 - (enterprise_base % 97))
    status = verified ? "verified" : "pending"
    verified_at = verified ? Time.current : nil

    user = User.create!(
      email_address: "#{token}@example.test",
      password: "password1234",
      first_name: prefix.capitalize,
      last_name: "Lawyer",
      locale: "en",
      system_role: system_role,
      email_verified_at: email_verified ? Time.current : nil
    )
    firm = Firm.create!(
      name: "#{prefix.capitalize} Legal",
      enterprise_number: enterprise_number,
      verification_status: status,
      verified_at: verified_at
    )
    user.memberships.create!(firm: firm, role: "owner")
    profile = user.create_lawyer_profile!(
      bar_association: "OVB",
      bar_number: token,
      professional_email: user.email_address,
      verification_status: status,
      verified_at: verified_at
    )

    Account.new(user:, firm:, profile:)
  end

  def create_assignment_for(account, title: "Test assignment", status: "open")
    account.firm.assignments.create!(
      creator_user: account.user,
      kind: "court_replacement",
      title: title,
      description: "A bounded assignment without client-identifying information.",
      city: "Brussels",
      court: "Enterprise Court",
      starts_at: 2.days.from_now,
      duration_minutes: 60,
      practice_area: "Commercial law",
      fee_cents: 250_00,
      content_rules_accepted_at: Time.current,
      status: status
    )
  end

  def invoice_recipient_attributes
    {
      invoice_name: "Synthetic recipient", invoice_enterprise_number: "1234567894",
      invoice_email: "invoices@example.test", invoice_address_line_1: "Test Street 1",
      invoice_postal_code: "1000", invoice_city: "Brussels"
    }
  end

  def create_proposal_for(assignment, account, message: "I am available for this assignment.", rate_cents: 250_00)
    assignment.proposals.create!(
      user: account.user,
      firm: account.firm,
      name: account.user.full_name,
      email: account.user.email_address,
      rate_cents: rate_cents,
      message: message
    )
  end
end
