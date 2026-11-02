module Privacy
  class RequestContext
    class InvalidRequest < StandardError; end

    def initialize(request:, actor:, kind:, self_service: false, scheduled_deletion_request_id: nil)
      @request = request
      @actor = actor
      @kind = kind
      @self_service = self_service
      @scheduled_deletion_request_id = scheduled_deletion_request_id
    end

    def user
      @request.user
    end

    def validate!
      @actor.reload
      @request.reload
      if @kind == "deletion" && AccountDeletionRequest.where(privacy_request_id: @request.id).where.not(cancelled_at: nil).exists?
        raise InvalidRequest, "This account deletion request was cancelled by its owner."
      end
      return validate_self_service! if @self_service

      valid = @actor.system_admin? && @actor.active? && @actor.admin_mfa_configured? &&
        @request.kind == @kind && @request.status == "in_review" &&
        @request.handled_by_user_id == @actor.id && !user.system_admin?
      raise InvalidRequest, "Use a member request assigned to an active MFA-configured administrator and marked in review." unless valid
    end

    private

    def validate_self_service!
      valid_actor = @scheduled_deletion_request_id ? scheduled_deletion_valid? : @actor.active?
      valid = valid_actor && !@actor.system_admin? &&
        @request.user_id == @actor.id && @request.kind == @kind && @request.status == "pending" &&
        @request.handled_by_user_id.nil?
      raise InvalidRequest, "Use a new deletion request belonging to the signed-in member." unless valid
    end

    def scheduled_deletion_valid?
      return false unless @kind == "deletion" && @actor.deletion_recoverable?

      deletion = AccountDeletionRequest.find_by(id: @scheduled_deletion_request_id, user_id: @actor.id)
      deletion && deletion.privacy_request_id == @request.id && deletion.current_cycle?(@actor) &&
        deletion.scheduled_at <= Time.current && deletion.finalization_status == "sending"
    end
  end
end
