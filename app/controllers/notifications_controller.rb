class NotificationsController < ApplicationController
  before_action :require_verified_lawyer
  before_action :set_notification, only: %i[show update]

  def index
    @filter = params[:filter].presence_in(%w[unread])
    scope = current_user.notifications
    @unread_count = scope.unread.count
    scope = scope.unread if @filter == "unread"
    @total_count = scope.count
    @total_pages = [ (@total_count.to_f / 25).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @notifications = scope.includes(:subject).order(created_at: :desc, id: :desc)
      .offset((@page - 1) * 25).limit(25)
    load_visible_assignments
  end

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
    destination = params[:from] == "notifications" ? notifications_path(filter: params[:filter].presence_in(%w[unread])) : dashboard_path
    redirect_to destination, notice: t("workflow.notices.notifications_marked_read")
  end

  private

  def set_notification
    @notification = current_user.notifications.find(params[:id])
  end

  def mark_read
    @notification.read! if @notification.read_at.nil?
  end

  def load_visible_assignments
    ids = @notifications.to_h do |notification|
      [ notification.id, assignment_id_for(notification) ]
    end
    assignments = Assignment.where(id: ids.values.compact).index_by(&:id)
    @notification_assignments = ids.transform_values do |assignment_id|
      assignment = assignments[assignment_id]
      assignment if assignment&.visible_to?(current_user)
    end
  end

  def destination_path
    assignment = Assignment.find_by(id: assignment_id_for(@notification))

    assignment&.visible_to?(current_user) ? assignment_path(assignment) : dashboard_path
  end

  def assignment_id_for(notification)
    subject = notification.subject
    id = case subject
    when Assignment then subject.id
    when Proposal then subject.assignment_id
    else
      data = notification.data
      data["assignment_id"] || data[:assignment_id] if data.is_a?(Hash)
    end
    Integer(id, exception: false)
  end
end
