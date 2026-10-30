module BusinessLookupHelper
  def business_lookup_source_label(snapshot_date:, fields: [])
    return if snapshot_date.blank? || fields.empty?

    date = snapshot_date.is_a?(Date) ? snapshot_date : Date.iso8601(snapshot_date)
    label = t("business_lookup.source", date: l(date, format: :default))
    selected = fields.map(&:to_s) & BusinessRegistry::Preview::FIELDS
    return if selected.empty?
    return label if selected.sort == BusinessRegistry::Preview::FIELDS.sort

    "#{label} · #{selected.map { |field| t("business_lookup.fields.#{field}") }.join(', ')}"
  rescue Date::Error
    nil
  end
end
