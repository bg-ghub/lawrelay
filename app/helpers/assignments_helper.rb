module AssignmentsHelper
  def assignment_hearing_details(assignment)
    details = CourtHearingLocations.find(name: assignment.court, city: assignment.city)
    {
      court: details&.court_name || assignment.court,
      location: details&.address || assignment.city,
      address_unavailable: details.present? && details.address.blank?
    }
  end
end
