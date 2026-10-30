class AddInvoiceRecipientToAssignments < ActiveRecord::Migration[8.0]
  def change
    add_column :assignments, :invoice_name, :string
    add_column :assignments, :invoice_enterprise_number, :string
    add_column :assignments, :invoice_email, :string
    add_column :assignments, :invoice_address_line_1, :string
    add_column :assignments, :invoice_postal_code, :string
    add_column :assignments, :invoice_city, :string
  end
end
