class ProposalsController < ApplicationController
  rate_limit to: 30, within: 1.hour, only: :create, by: -> { current_user&.id },
    with: -> { redirect_to @assignment || assignments_path, alert: t("workflow.errors.rate_limited") }

  before_action :require_verified_lawyer
  before_action :set_assignment
  before_action :set_proposal, only: %i[accept decline withdraw]

  def create
    if @assignment.owned_by?(current_user)
      return redirect_to @assignment, alert: t("workflow.errors.cannot_propose_to_own_assignment")
    end

    saved = @assignment.with_lock do
      next false unless @assignment.accepting_proposals?

      @proposal = @assignment.proposals.build(proposal_params)
      @proposal.user = current_user
      @proposal.firm = current_firm
      @proposal.name = current_user.full_name
      @proposal.email = current_user.email_address
      @proposal.save.tap do |created|
        @proposal.audit_events.create!(actor_user: current_user, firm: current_firm, action: "proposal.created") if created
      end
    end

    if @proposal.nil?
      redirect_to @assignment, alert: t("workflow.errors.assignment_not_open")
    elsif saved
      redirect_to @assignment, notice: t("notices.proposal_created")
    else
      @owner_view = false
      @existing_proposal = nil
      @proposals = Proposal.none
      render "assignments/show", status: :unprocessable_content
    end
  end

  def accept
    return owner_only unless @assignment.manageable_by?(current_user)

    @assignment.with_lock do
      @proposal.reload
      unless @assignment.status == "open" && @assignment.starts_at > Time.current && @proposal.status == "pending"
        raise ActiveRecord::RecordInvalid, @assignment
      end

      @proposal.accept!(actor: current_user)
      @assignment.proposals.where.not(id: @proposal.id).where(status: "pending").find_each do |other_proposal|
        other_proposal.decline!(actor: current_user)
      end
      @assignment.update!(status: "matched")
      @assignment.audit_events.create!(actor_user: current_user, firm: current_firm, action: "assignment.matched", metadata: { proposal_id: @proposal.id })
      @assignment.notify_creator_of_match!(actor: current_user)
    end

    redirect_to @assignment, notice: t("workflow.notices.proposal_accepted")
  rescue ActiveRecord::RecordInvalid, Proposal::InvalidTransition
    redirect_to @assignment, alert: t("workflow.errors.cannot_accept_proposal")
  end

  def decline
    return owner_only unless @assignment.manageable_by?(current_user)

    @proposal.decline!(actor: current_user)
    redirect_to @assignment, notice: t("workflow.notices.proposal_declined")
  rescue Proposal::InvalidTransition
    redirect_to @assignment, alert: t("workflow.errors.cannot_decline_proposal")
  end

  def withdraw
    unless @proposal.owned_by?(current_user)
      return redirect_to @assignment, alert: t("workflow.errors.proposer_only")
    end

    @proposal.withdraw!(actor: current_user)
    redirect_to @assignment, notice: t("workflow.notices.proposal_withdrawn")
  rescue Proposal::InvalidTransition
    redirect_to @assignment, alert: t("workflow.errors.cannot_withdraw_proposal")
  end

  private

  def set_assignment
    @assignment = Assignment.includes(:creator_user, :firm).find(params[:assignment_id])
  end

  def set_proposal
    @proposal = @assignment.proposals.find(params[:id])
  end

  def owner_only
    redirect_to @assignment, alert: t("workflow.errors.owner_only")
  end

  def proposal_params
    attributes = params.require(:proposal).permit(:rate_cents, :rate_kind, :message)
    attributes[:rate_cents] = euros_to_cents(attributes[:rate_cents])
    attributes
  end

  def euros_to_cents(value)
    return nil if value.blank?

    amount = BigDecimal(value.to_s.tr(",", "."))
    return value unless amount.finite?

    cents = amount * 100
    return cents.to_s if !cents.finite? || cents.abs > Proposal::MAX_RATE_CENTS

    cents.round.to_i
  rescue ArgumentError, FloatDomainError, RangeError
    value
  end
end
