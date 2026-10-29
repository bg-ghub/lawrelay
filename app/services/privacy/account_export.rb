module Privacy
  class AccountExport
    USER_FIELDS = %w[id first_name last_name email_address locale created_at updated_at email_verified_at
      accepted_terms_at accepted_terms_version accepted_privacy_version suspended_at two_factor_enabled_at].freeze
    PROFILE_FIELDS = %w[bar_association bar_number professional_email spoken_languages practice_areas verification_status
      verified_at bar_admission_year court_preferences availability_note directory_profile_url directory_profile_id
      directory_name directory_email directory_checked_at directory_email_verified_at created_at updated_at].freeze
    ASSIGNMENT_FIELDS = %w[id kind title description court city starts_at duration_minutes practice_area fee_cents status
      urgent languages content_rules_accepted_at assignment_subtype response_deadline_at scope_indication delivery_due_at
      created_at updated_at].freeze
    PROPOSAL_FIELDS = %w[id assignment_id name email rate_cents rate_kind message status accepted_at declined_at
      withdrawn_at created_at updated_at].freeze

    def initialize(request:, actor:)
      @request = request
      @actor = actor
      @context = RequestContext.new(request:, actor:, kind: "access_export")
    end

    def call(output_path:)
      file = PrivateJsonFile.new(output_path)
      PrivacyRequest.transaction do
        @request.lock!
        @context.validate!
        file.write!(package)
        AuditEvent.create!(auditable: @request, actor_user: @actor, action: "privacy.export_prepared",
          metadata: { source: "rake", format_version: 1 })
      end
      true
    rescue StandardError
      file.remove_created!
      raise
    end

    private

    def package
      user = @context.user
      {
        format_version: 1,
        prepared_at: Time.current.iso8601,
        request_id: @request.id,
        review_required: true,
        limitations: [
          "Review authored free text for third-party information before release.",
          "Administrator notes, audit metadata, other users' records and shared firm/billing records are excluded; assess separately.",
          "Support email, host/provider logs, backups and external provider records require separate review.",
          "Preparing this package does not complete the request or establish that every access obligation is fulfilled."
        ],
        account: user.attributes.slice(*USER_FIELDS),
        professional_profile: user.lawyer_profile&.attributes&.slice(*PROFILE_FIELDS),
        memberships: rows(user.memberships, %w[firm_id role created_at updated_at]),
        authored_assignments: rows(user.created_assignments, ASSIGNMENT_FIELDS),
        authored_proposals: rows(user.proposals, PROPOSAL_FIELDS),
        notifications: rows(user.notifications, %w[id kind read_at email_status email_sent_at created_at updated_at]),
        privacy_requests: rows(user.privacy_requests, %w[id kind status details resolved_at created_at updated_at]),
        submitted_reports: rows(user.submitted_reports, %w[id reportable_type reportable_id category status details resolved_at created_at updated_at]),
        account_audit_events: rows(AuditEvent.where(auditable: user), %w[action created_at]),
        sessions: rows(user.sessions, %w[ip_address user_agent created_at expires_at last_seen_at])
      }
    end

    def rows(relation, fields)
      relation.order(:id).map { |record| record.attributes.slice(*fields) }
    end
  end
end
