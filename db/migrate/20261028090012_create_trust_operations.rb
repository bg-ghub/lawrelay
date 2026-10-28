class CreateTrustOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :privacy_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.text :details, null: false
      t.references :handled_by_user, foreign_key: { to_table: :users }
      t.text :resolution_note
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :privacy_requests, %i[status created_at]

    create_table :reports do |t|
      t.references :reporter_user, null: false, foreign_key: { to_table: :users }
      t.references :reportable, polymorphic: true, null: false
      t.string :category, null: false
      t.string :status, null: false, default: "open"
      t.text :details, null: false
      t.references :reviewed_by_user, foreign_key: { to_table: :users }
      t.text :resolution_note
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :reports, %i[status created_at]
  end
end
