require "digest"

# Monitoring evidence is deliberately separate from verification/access evidence.
class RegistryStatusCheck < ApplicationRecord
  SOURCES = %w[directory].freeze
  STATUSES = %w[pending active not_listed changed unavailable].freeze

  belongs_to :firm, optional: true
  belongs_to :lawyer_profile, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :target_digest, :identity_digest, presence: true

  scope :issues, -> { where.not(issue_status: nil) }

  def self.relevant
    targets = RegistryStatus::Targets.all.index_by(&:digest)
    ids = where(source: "directory").filter_map do |check|
      target = targets[check.target_digest]
      check.id if target && check.identity_digest == target.identity_digest &&
        check.firm_id == target.firm_id && check.lawyer_profile_id == target.lawyer_profile_id
    end
    where(id: ids)
  end

  def relevant_users
    members = User.where(system_role: "member", erased_at: nil)
    return members.none unless source == "directory" && lawyer_profile

    url = Directory::AdvocaatBeProfileLookup.canonical_profile_url(lawyer_profile.directory_profile_url)&.downcase
    name = lawyer_profile.directory_name.presence || lawyer_profile.user.full_name
    identity = self.class.digest("directory_identity", [ name, lawyer_profile.directory_email.presence ].join("\u0000"))
    expected_digest = self.class.target_digest(source: "directory", value: url, lawyer_profile_id: lawyer_profile.id)
    return members.none unless url && expected_digest == target_digest && identity == identity_digest

    members.where(id: lawyer_profile.user_id).order(:id)
  end

  def self.digest(source, value)
    Digest::SHA256.hexdigest([ source, value ].join("\u0000"))
  end

  def self.target_digest(source:, value:, lawyer_profile_id: nil)
    digest(source, source == "directory" ? [ lawyer_profile_id, value ].join("\u0000") : value)
  end

  def target
    lawyer_profile
  end

  def actionable?(outcome = status)
    outcome.in?(%w[not_listed changed])
  end

  # Caller holds the run transaction, so finding and issue dedup commit together.
  def record_result!(outcome:, checked_at:, run_on:, identity_digest:)
    if self.identity_digest.present? && self.identity_digest != identity_digest
      assign_attributes(last_definitive_status: nil, last_definitive_at: nil, issue_status: nil,
        issue_since: nil, resolved_at: nil, last_alerted_at: nil)
    end
    outcome = outcome.to_s
    allowed = %w[active not_listed changed unavailable]
    outcome = "unavailable" unless outcome.in?(allowed)
    new_issue = false
    assign_attributes(status: outcome, checked_at:, last_run_on: run_on, identity_digest:)

    definitive = outcome.in?(%w[active not_listed changed])
    if definitive
      assign_attributes(last_definitive_status: outcome, last_definitive_at: checked_at)
      if actionable?(outcome)
        new_issue = issue_status != outcome
        assign_attributes(issue_status: outcome, issue_since: checked_at, resolved_at: nil, last_alerted_at: nil) if new_issue
      elsif issue_status.present?
        assign_attributes(issue_status: nil, issue_since: nil, resolved_at: checked_at)
      end
    end
    save!
    new_issue
  end

  def finding_snapshot
    { "check_id" => id, "source" => source, "status" => issue_status, "issue_since" => issue_since&.iso8601(6),
      "lawyer_profile_id" => lawyer_profile_id }
  end

  def sanitize_finding(finding)
    finding.slice("check_id", "status", "issue_since").merge("source" => source, "lawyer_profile_id" => lawyer_profile_id)
  end
end
