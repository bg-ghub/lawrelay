module AssignmentsHelper
  COURT_ADDRESS_NOTES = {
    "3ème étage" => "third_floor",
    "1er étage" => "first_floor",
    "eerste verdieping" => "first_floor",
    "Bâtiment du SPF Finances" => "finance_building"
  }.freeze

  def assignment_hearing_details(assignment)
    details = CourtHearingLocations.find(name: assignment.court, city: assignment.city)
    address = details&.address
    {
      court: details&.court_name || assignment.court,
      location: address ? localized_court_address_notes(address) : assignment.city,
      address_unavailable: details.present? && details.address.blank?
    }
  end

  private

  # Only canonical hearing addresses reach this method. Street names and
  # unreviewed annotations remain exactly as published.
  def localized_court_address_notes(address)
    address.gsub(/\(([^()]*)\)/) do |annotation|
      key = COURT_ADDRESS_NOTES[Regexp.last_match(1).strip]
      key ? "(#{t("court_address_notes.#{key}")})" : annotation
    end
  end
end
