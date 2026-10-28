class AddStructuredAssignmentFields < ActiveRecord::Migration[8.1]
  def up
    add_column :assignments, :assignment_subtype, :string
    add_column :assignments, :response_deadline_at, :datetime
    add_column :assignments, :scope_indication, :string
    add_column :assignments, :delivery_due_at, :datetime
    add_index :assignments, :response_deadline_at
    execute "UPDATE assignments SET assignment_subtype = CASE kind WHEN 'court_replacement' THEN 'hearing' ELSE 'advice' END"
    execute "UPDATE assignments SET response_deadline_at = datetime(starts_at, '-1 hour')"

    add_column :proposals, :rate_kind, :string, null: false, default: "fixed"
  end

  def down
    remove_column :proposals, :rate_kind
    remove_index :assignments, :response_deadline_at
    remove_column :assignments, :delivery_due_at
    remove_column :assignments, :scope_indication
    remove_column :assignments, :response_deadline_at
    remove_column :assignments, :assignment_subtype
  end
end
