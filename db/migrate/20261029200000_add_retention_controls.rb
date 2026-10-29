class AddRetentionControls < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :erased_at, :datetime
    add_index :users, :erased_at
    add_column :assignments, :closed_at, :datetime
    add_index :assignments, [ :status, :closed_at ]
    execute "UPDATE assignments SET closed_at = updated_at WHERE status IN ('completed', 'cancelled', 'expired')"

    create_table :retention_holds do |t|
      t.references :subject, polymorphic: true, null: false
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.text :reason, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :expires_at
    end
  end

  def down
    drop_table :retention_holds
    remove_column :assignments, :closed_at
    remove_column :users, :erased_at
  end
end
