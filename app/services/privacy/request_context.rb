module Privacy
  class RequestContext
    class InvalidRequest < StandardError; end

    def initialize(request:, actor:, kind:, self_service: false)
      @request = request
      @actor = actor
      @kind = kind
      @self_service = self_service
    end

    def user
      @request.user
    end

    def validate!
      @actor.reload
      @request.reload
      return validate_self_service! if @self_service

      valid = @actor.system_admin? && @actor.active? && @actor.admin_mfa_configured? &&
        @request.kind == @kind && @request.status == "in_review" &&
        @request.handled_by_user_id == @actor.id && !user.system_admin?
      raise InvalidRequest, "Use a member request assigned to an active MFA-configured administrator and marked in review." unless valid
    end

    private

    def validate_self_service!
      valid = @actor.active? && !@actor.system_admin? &&
        @request.user_id == @actor.id && @request.kind == @kind && @request.status == "pending" &&
        @request.handled_by_user_id.nil?
      raise InvalidRequest, "Use a new deletion request belonging to the signed-in member." unless valid
    end
  end
end
