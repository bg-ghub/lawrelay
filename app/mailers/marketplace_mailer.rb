class MarketplaceMailer < ApplicationMailer
  def new_proposal(proposal)
    @proposal = proposal
    @assignment = proposal.assignment
    @recipient = @assignment.creator_user
    localized_mail(@recipient, "new_proposal")
  end

  def proposal_accepted(proposal)
    @proposal = proposal
    @assignment = proposal.assignment
    @recipient = proposal.user
    localized_mail(@recipient, "proposal_accepted")
  end

  def proposal_declined(proposal)
    @proposal = proposal
    @assignment = proposal.assignment
    @recipient = proposal.user
    localized_mail(@recipient, "proposal_declined")
  end

  # locale remains optional so jobs queued before locale-specific delivery was
  # introduced retain their previous behaviour.
  def assignment_cancelled(assignment, locale: nil)
    @assignment = assignment
    recipients = assignment.proposals.includes(:user).filter_map(&:user).uniq
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

  def localized_mail(recipient, key)
    return unless recipient

    I18n.with_locale(recipient.locale) do
      mail(
        to: recipient.email_address,
        subject: I18n.t("workflow.mailers.#{key}.subject", title: @assignment.title)
      )
    end
  end
end
