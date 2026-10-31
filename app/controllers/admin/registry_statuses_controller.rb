module Admin
  class RegistryStatusesController < BaseController
    def index
      @latest_run = RegistryStatusRun.order(run_on: :desc, id: :desc).first
      scope = RegistryStatusCheck.relevant
      @total_pages = [ (scope.count / 100.0).ceil, 1 ].max
      @page = params[:page].to_i.clamp(1, @total_pages)
      @checks = scope.includes(lawyer_profile: :user)
        .order(checked_at: :desc, id: :desc).offset((@page - 1) * 100).limit(100)
    end
  end
end
