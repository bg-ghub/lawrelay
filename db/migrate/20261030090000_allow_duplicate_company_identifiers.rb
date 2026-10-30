class AllowDuplicateCompanyIdentifiers < ActiveRecord::Migration[8.0]
  def up
    remove_index :firms, name: "index_firms_on_enterprise_number"
    remove_index :firms, name: "index_firms_on_vat_number"

    add_index :firms, :enterprise_number, where: "enterprise_number IS NOT NULL"
    add_index :firms, :vat_number, where: "vat_number IS NOT NULL"
  end

  def down
    remove_index :firms, :enterprise_number
    remove_index :firms, :vat_number

    add_index :firms, :enterprise_number, unique: true, where: "enterprise_number IS NOT NULL"
    add_index :firms, :vat_number, unique: true, where: "vat_number IS NOT NULL"
  end
end
