class CreateProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :proposals do |t|
      t.references :assignment, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false
      t.integer :rate_cents, null: false
      t.text :message, null: false
      t.string :status, null: false, default: "pending"

      t.timestamps
    end

    add_index :proposals, :status
  end
end
