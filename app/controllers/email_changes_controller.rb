class EmailChangesController < ApplicationController
  before_action :require_member_account
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def new
  end

  def create
    redirect_to email_change_path, status: :see_other
  end

  private

  def require_member_account
    head :forbidden if current_user.system_admin?
  end
end
