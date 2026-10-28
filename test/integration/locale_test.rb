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
        content_rules_accepted: "1"
      }
    }

    assignment = Assignment.order(:id).last

    assert_redirected_to "/fr/assignments/#{assignment.id}"
    assert_equal "Votre mission a été publiée. Des confrères peuvent maintenant y répondre.", flash[:notice]
    assert_nil assignment.languages
  end
end
