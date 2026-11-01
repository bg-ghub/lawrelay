class AddProposalTravelTerms < ActiveRecord::Migration[8.1]
  def change
    add_column :proposals, :travel_included, :boolean
    add_column :proposals, :travel_cost_cents, :bigint
  end
end
