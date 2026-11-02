class AddProposalTravelCostKind < ActiveRecord::Migration[8.1]
  def up
    add_column :proposals, :travel_cost_kind, :string
    execute <<~SQL
      UPDATE proposals
      SET travel_cost_kind = 'fixed'
      WHERE travel_included = FALSE AND travel_cost_cents IS NOT NULL
    SQL
  end

  def down
    if select_value("SELECT 1 FROM proposals WHERE travel_cost_kind = 'per_km' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Per-kilometre travel offers must be preserved; use a compatible forward fix."
    end

    remove_column :proposals, :travel_cost_kind
  end
end
