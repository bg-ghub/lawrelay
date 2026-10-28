class NotificationsController < ApplicationController
  before_action :require_verified_lawyer
  before_action :set_notification, only: %i[show update]

  # Notifications are resolved through the current user's scope. The stored
  # subject never acts as an authorization grant.
  def show
    mark_read
    redirect_to destination_path
  end

  def update
    mark_read
    redirect_to dashboard_path, notice: t("workflow.notices.notification_marked_read")
  end

  def mark_all
    current_user.notifications.unread.update_all(read_at: Time.current, updated_at: Time.current)
    redirect_to dashboard_path, notice: t("workflow.notices.notifications_marked_read")
  end

  private

  def set_notification
    @notification = current_user.notifications.find(params[:id])
  end

  def mark_read
    @notification.read! if @notification.read_at.nil?
  end

  def destination_path
    assignment_id = @notification.data["assignment_id"] || @notification.data[:assignment_id]
    assignment = Assignment.find_by(id: assignment_id)

    assignment&.visible_to?(current_user) ? assignment_path(assignment) : dashboard_path
  end
end
