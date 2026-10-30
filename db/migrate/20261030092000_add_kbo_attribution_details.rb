class AddKboAttributionDetails < ActiveRecord::Migration[8.0]
  def change
    add_column :firms, :kbo_details, :json, null: false, default: {}
    add_column :assignments, :invoice_kbo_details, :json, null: false, default: {}
  end
end
