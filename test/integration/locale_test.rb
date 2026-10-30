require "test_helper"

class LocaleTest < ActionDispatch::IntegrationTest
  setup do
    user = users(:one)
    firm = Firm.create!(name: "Locale Test Firm", enterprise_number: "LOCALE0001", verification_status: "verified", verified_at: Time.current)
    Membership.create!(user: user, firm: firm, role: "owner")
    LawyerProfile.create!(
      user: user,
      bar_association: "OVB",
      bar_number: "LOCALE-001",
      verification_status: "verified",
      verified_at: Time.current
    )
    sign_in_as(user)
  end

  test "locale-prefixed assignment creation keeps the locale in redirects and messages" do
    post "/fr/assignments", params: {
      assignment: {
        kind: "court_replacement",
        title: "Audience de remplacement",
        description: "Une mission limitée sans informations confidentielles.",
        court: "Tribunal de l'entreprise de Bruxelles",
        city: "Bruxelles",
        starts_at: 2.days.from_now,
        duration_minutes: 60,
        practice_area: "Droit commercial",
        languages: "FR",
        content_rules_accepted: "1",
        invoice_name: "Synthetic recipient", invoice_enterprise_number: "1234567894",
        invoice_email: "invoices@example.test", invoice_address_line_1: "Test Street 1",
        invoice_postal_code: "1000", invoice_city: "Brussels"
      }
    }

    assignment = Assignment.order(:id).last

    assert_redirected_to "/fr/assignments/#{assignment.id}"
    assert_equal I18n.t("notices.assignment_created", locale: :fr), flash[:notice]
    assert_nil assignment.languages
  end
end
