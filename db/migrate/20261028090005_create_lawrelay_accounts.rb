class CreateLawrelayAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string :first_name, null: false, default: ""
      t.string :last_name, null: false, default: ""
      t.string :locale, null: false, default: "nl"
      t.string :system_role, null: false, default: "member"
      t.datetime :email_verified_at
      t.datetime :accepted_terms_at
      t.string :accepted_terms_version
      t.string :accepted_privacy_version
    end

    create_table :firms do |t|
      t.string :name, null: false
      t.string :enterprise_number
      t.string :vat_number
      t.string :billing_email
      t.string :phone
      t.string :address_line_1
      t.string :postal_code
      t.string :city
      t.string :country_code, null: false, default: "BE"
      t.string :verification_status, null: false, default: "pending"
      t.datetime :verified_at
      t.timestamps
    end
    add_index :firms, :enterprise_number, unique: true, where: "enterprise_number IS NOT NULL"
    add_index :firms, :vat_number, unique: true, where: "vat_number IS NOT NULL"
    add_index :firms, :verification_status

    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :firm, null: false, foreign_key: true
      t.string :role, null: false, default: "member"
      t.timestamps
    end
    add_index :memberships, %i[user_id firm_id], unique: true

    create_table :lawyer_profiles do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :bar_association, null: false
      t.string :bar_number, null: false
      t.string :professional_email
      t.json :spoken_languages, null: false, default: []
      t.json :practice_areas, null: false, default: []
      t.string :verification_status, null: false, default: "pending"
      t.datetime :verified_at
      t.text :verification_note
      t.timestamps
    end
    add_index :lawyer_profiles, %i[bar_association bar_number], unique: true
    add_index :lawyer_profiles, :verification_status
  end
end
