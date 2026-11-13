class TrackPendingNewAssignmentAlerts < ActiveRecord::Migration[8.1]
  def change
    add_column :assignments, :new_assignment_alerts_pending, :boolean, default: false, null: false
  end
end
