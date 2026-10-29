class MarketplaceMailer < ApplicationMailer
  def new_proposal(proposal, recipient: proposal.assignment.creator_user)
    @proposal = proposal
    @assignment = proposal.assignment
    localized_mail(recipient, "new_proposal")
  end

  def proposal_accepted(proposal, recipient: proposal.user)
    @proposal = proposal
    @assignment = proposal.assignment
    localized_mail(recipient, "proposal_accepted")
  end

  def proposal_declined(proposal, recipient: proposal.user)
    @proposal = proposal
    @assignment = proposal.assignment
    localized_mail(recipient, "proposal_declined")
  end

  def proposal_withdrawn(proposal, recipient: proposal.assignment.creator_user)
    @proposal = proposal
    @assignment = proposal.assignment
    localized_mail(recipient, "proposal_withdrawn", template_name: "lifecycle_event")
  end

  def assignment_matched(assignment, recipient: assignment.creator_user)
    @assignment = assignment
    localized_mail(recipient, "assignment_matched", template_name: "lifecycle_event")
  end

  def assignment_completed(assignment, recipient: assignment.accepted_proposal&.user)
    @assignment = assignment
    localized_mail(recipient, "assignment_completed", template_name: "lifecycle_event")
  end

  def assignment_expired(assignment, recipient: assignment.creator_user)
    @assignment = assignment
    @body_key = recipient&.id == assignment.creator_user_id ? "body_owner" : "body_candidate"
    localized_mail(recipient, "assignment_expired", template_name: "lifecycle_event")
  end

  def response_deadline_closed(assignment, recipient: assignment.creator_user)
    @assignment = assignment
    localized_mail(recipient, "response_deadline_closed", template_name: "lifecycle_event")
  end

  # Keep the locale API for jobs queued before individual delivery was added.
  def assignment_cancelled(assignment, recipient: :legacy, locale: nil)
    @assignment = assignment
    unless recipient == :legacy
      return localized_mail(recipient, "assignment_cancelled", template_name: "lifecycle_event")
    end

    recipients = assignment.proposals.where(status: %w[pending accepted]).includes(:user).filter_map(&:user).uniq
    recipients.select! { |candidate| deliverable_recipient?(candidate) }
    recipients.select! { |recipient| recipient.locale == locale.to_s } if locale.present?
    return if recipients.empty?

    I18n.with_locale(locale.presence || assignment.creator_user&.locale || I18n.default_locale) do
      mail(
        to: ENV.fetch("MAILER_FROM", "no-reply@lawrelay.be"),
        bcc: recipients.map(&:email_address),
        subject: I18n.t("workflow.mailers.assignment_cancelled.subject", title: assignment.title)
      )
    end
  end

  private

  def localized_mail(recipient, key, template_name: nil)
    return unless deliverable_recipient?(recipient)

    @recipient = recipient
    @event_key = key
    I18n.with_locale(recipient.locale) do
      headers = {
        to: recipient.email_address,
        subject: I18n.t("workflow.mailers.#{key}.subject", title: @assignment.title)
      }
      headers[:template_name] = template_name if template_name
      mail(**headers)
    end
  end

  def deliverable_recipient?(recipient)
    recipient&.reload&.marketplace_verified?
  rescue ActiveRecord::RecordNotFound
    false
  end
end
