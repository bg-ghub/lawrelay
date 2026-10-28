class CreateAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :assignments do |t|
      t.string :kind, null: false, default: "court_replacement"
      t.string :title, null: false
      t.text :description, null: false
      t.string :court
      t.string :city, null: false
      t.datetime :starts_at, null: false
      t.integer :duration_minutes, null: false, default: 60
      t.string :practice_area, null: false
      t.integer :fee_cents
      t.string :status, null: false, default: "open"
      t.boolean :urgent, null: false, default: false
      t.string :languages, null: false, default: "NL"

      t.timestamps
    end

    add_index :assignments, :kind
    add_index :assignments, :status
    add_index :assignments, :starts_at
    add_index :assignments, :city
    add_index :assignments, :practice_area
  end
end
