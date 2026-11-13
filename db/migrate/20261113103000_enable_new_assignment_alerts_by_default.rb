class EnableNewAssignmentAlertsByDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :users, :new_assignment_alerts, from: false, to: true

    # The previous default was off. The settings audit distinguishes a saved
    # opt-out from a member who never changed the setting.
    execute <<~SQL
      UPDATE users
      SET new_assignment_alerts = TRUE
      WHERE system_role = 'member' AND erased_at IS NULL AND new_assignment_alerts = FALSE
        AND NOT EXISTS (
          SELECT 1 FROM audit_events, json_each(audit_events.metadata, '$.changed_fields') AS field
          WHERE audit_events.auditable_type = 'User' AND audit_events.auditable_id = users.id
            AND audit_events.action = 'account.updated' AND field.value = 'new_assignment_alerts'
        )
    SQL
  end

  def down
    change_column_default :users, :new_assignment_alerts, from: true, to: false
  end
end
