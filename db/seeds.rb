if Rails.env.production?
  warn "LawRelay production seeds intentionally contain no demo users or assignments."
  return
end

demo_password = ENV.fetch("LAWRELAY_DEMO_PASSWORD", "LawRelayDemo!2026")

def verified_firm!(name:, enterprise_number:, email:)
  Firm.find_or_initialize_by(name: name, enterprise_number: enterprise_number).tap do |firm|
    firm.assign_attributes(
      name: name,
      billing_email: email,
      country_code: "BE",
      verification_status: "verified",
      verified_at: Time.current
    )
    firm.save!
  end
end

def verified_user!(email:, first_name:, last_name:, password:, firm:, bar_number:)
  User.find_or_initialize_by(email_address: email).tap do |user|
    user.assign_attributes(
      first_name: first_name,
      last_name: last_name,
      password: password,
      password_confirmation: password,
      locale: "nl",
      email_verified_at: Time.current,
      accepted_terms_at: Time.current,
      accepted_terms_version: "2026-10-28",
      accepted_privacy_version: "2026-10-28"
    )
    user.save!
    user.memberships.find_or_create_by!(firm: firm) { |membership| membership.role = "owner" }
    profile = user.lawyer_profile || user.build_lawyer_profile
    profile.assign_attributes(
      bar_association: "OVB",
      bar_number: bar_number,
      professional_email: email,
      spoken_languages: %w[NL EN],
      practice_areas: %w[commercial family],
      verification_status: "verified",
      verified_at: Time.current
    )
    profile.save!
  end
end

owner_firm = verified_firm!(
  name: "Demo Advocaten",
  enterprise_number: "DEMO000001",
  email: "owner@lawrelay.test"
)
candidate_firm = verified_firm!(
  name: "Demo Confraters",
  enterprise_number: "DEMO000002",
  email: "candidate@lawrelay.test"
)

owner = verified_user!(
  email: "owner@lawrelay.test",
  first_name: "Marie",
  last_name: "De Smet",
  password: demo_password,
  firm: owner_firm,
  bar_number: "DEMO-OVB-001"
)
candidate = verified_user!(
  email: "candidate@lawrelay.test",
  first_name: "Thomas",
  last_name: "Peeters",
  password: demo_password,
  firm: candidate_firm,
  bar_number: "DEMO-OVB-002"
)

owner_firm.assignments.destroy_all
candidate_firm.assignments.destroy_all

assignments = [
  {
    kind: "court_replacement",
    title: "Demo · Pleiten op inleidingszitting",
    description: "Korte verschijning voor een dossier huurrecht. Volledige briefing en stukken worden buiten LawRelay gedeeld.",
    court: "Ondernemingsrechtbank Antwerpen",
    city: "Antwerpen",
    starts_at: Date.current.advance(days: 2).to_time.change(hour: 9, min: 30),
    duration_minutes: 45,
    practice_area: "Huurrecht",
    fee_cents: 175_00,
    content_rules_accepted_at: Time.current,
    creator_user: owner
  },
  {
    kind: "legal_task",
    title: "Demo · Conclusies nalezen en aanscherpen",
    description: "Second opinion gevraagd op ontwerpconclusies in een commercieel geschil. Geen cliëntgegevens op het platform.",
    city: "Gent",
    starts_at: Date.current.advance(days: 3).to_time.change(hour: 10),
    duration_minutes: 180,
    practice_area: "Handelsrecht",
    fee_cents: 420_00,
    content_rules_accepted_at: Time.current,
    languages: "NL / EN",
    creator_user: owner
  },
  {
    kind: "court_replacement",
    title: "Demo · Verschijning voor de familierechtbank",
    description: "Dossier is voorbereid; enkel vervanging ter zitting nodig. Details worden rechtstreeks gedeeld.",
    court: "Familierechtbank Brussel",
    city: "Brussel",
    starts_at: Date.current.advance(days: 4).to_time.change(hour: 14),
    duration_minutes: 60,
    practice_area: "Familierecht",
    fee_cents: 210_00,
    content_rules_accepted_at: Time.current,
    creator_user: owner
  },
  {
    kind: "legal_task",
    title: "Demo · Advies bij aandeelhoudersgeschil",
    description: "Gerichte analyse met beknopt strategisch advies. Vertrouwelijke stukken blijven buiten LawRelay.",
    city: "Leuven",
    starts_at: Date.current.advance(days: 5).to_time.change(hour: 9),
    duration_minutes: 240,
    practice_area: "Vennootschapsrecht",
    fee_cents: 600_00,
    content_rules_accepted_at: Time.current,
    languages: "NL / EN",
    creator_user: owner
  },
  {
    kind: "court_replacement",
    title: "Demo · Debat over verkeersinbreuk",
    description: "Pleitduur voorzien op 20 minuten. De briefing volgt rechtstreeks na de match.",
    court: "Politierechtbank Hasselt",
    city: "Hasselt",
    starts_at: Date.current.advance(days: 6).to_time.change(hour: 11),
    duration_minutes: 45,
    practice_area: "Verkeersrecht",
    fee_cents: 160_00,
    content_rules_accepted_at: Time.current,
    creator_user: owner
  }
].map { |attributes| owner_firm.assignments.create!(attributes) }

candidate_assignment = candidate_firm.assignments.create!(
  creator_user: candidate,
  kind: "legal_task",
  title: "Demo · Opmaak ingebrekestelling",
  description: "Opstellen van een onderbouwde ingebrekestelling. De dossierstukken worden rechtstreeks gedeeld.",
  city: "Mechelen",
  starts_at: Date.current.advance(days: 8).to_time.change(hour: 13),
  duration_minutes: 120,
  practice_area: "Bouwrecht",
  fee_cents: 285_00,
  content_rules_accepted_at: Time.current,
  languages: "NL"
)

assignments.first.proposals.create!(
  user: candidate,
  firm: candidate_firm,
  name: candidate.full_name,
  email: candidate.email_address,
  rate_cents: 175_00,
  message: "Ik verschijn regelmatig in Antwerpen en kan de briefing vooraf doornemen."
)
candidate_assignment.proposals.create!(
  user: owner,
  firm: owner_firm,
  name: owner.full_name,
  email: owner.email_address,
  rate_cents: 285_00,
  message: "Ik kan dit deze week opnemen en bezorg een beknopt ontwerp."
)

puts "Seeded verified demo accounts:"
puts "  owner@lawrelay.test / #{demo_password}"
puts "  candidate@lawrelay.test / #{demo_password}"
