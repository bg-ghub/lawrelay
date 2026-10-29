module Privacy
  class RequestContext
    class InvalidRequest < StandardError; end

    def initialize(request:, actor:, kind:)
      @request = request
      @actor = actor
      @kind = kind
    end

    def user
      @request.user
    end

    def validate!
      @actor.reload
      @request.reload
      valid = @actor.system_admin? && @actor.active? && @actor.admin_mfa_configured? &&
        @request.kind == @kind && @request.status == "in_review" &&
        @request.handled_by_user_id == @actor.id && !user.system_admin?
      raise InvalidRequest, "Use a member request assigned to an active MFA-configured administrator and marked in review." unless valid
    end
  end
end
