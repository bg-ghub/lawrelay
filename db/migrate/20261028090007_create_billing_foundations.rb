class CreateBillingFoundations < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_accounts do |t|
      t.references :firm, null: false, foreign_key: true, index: { unique: true }
      t.string :provider, null: false, default: "manual"
      t.string :provider_customer_id
      t.string :billing_email
      t.string :peppol_id
      t.string :plan_key, null: false, default: "founding_beta"
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
    add_index :billing_accounts, %i[provider provider_customer_id], unique: true, where: "provider_customer_id IS NOT NULL", name: "index_billing_accounts_on_provider_customer"

    create_table :subscriptions do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.string :provider, null: false, default: "manual"
      t.string :provider_subscription_id
      t.string :plan_key, null: false, default: "lawrelay_office"
      t.string :status, null: false, default: "trialing"
      t.integer :amount_cents, null: false, default: 4900
      t.string :currency, null: false, default: "EUR"
      t.string :interval, null: false, default: "month"
      t.string :idempotency_key, null: false
      t.datetime :starts_at
      t.datetime :current_period_ends_at
      t.datetime :cancelled_at
      t.datetime :suspended_at
      t.timestamps
    end
    add_index :subscriptions, %i[provider provider_subscription_id], unique: true, where: "provider_subscription_id IS NOT NULL", name: "index_subscriptions_on_provider_subscription"
    add_index :subscriptions, :idempotency_key, unique: true
    add_index :subscriptions, :status

    create_table :billing_payments do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.references :subscription, foreign_key: true
      t.string :provider, null: false, default: "manual"
      t.string :provider_payment_id
      t.string :status, null: false, default: "pending"
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "EUR"
      t.string :idempotency_key, null: false
      t.datetime :paid_at
      t.datetime :refunded_at
      t.timestamps
    end
    add_index :billing_payments, %i[provider provider_payment_id], unique: true, where: "provider_payment_id IS NOT NULL", name: "index_billing_payments_on_provider_payment"
    add_index :billing_payments, :idempotency_key, unique: true
    add_index :billing_payments, :status

    create_table :invoices do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.references :subscription, foreign_key: true
      t.string :number
      t.string :status, null: false, default: "draft"
      t.string :currency, null: false, default: "EUR"
      t.integer :subtotal_cents, null: false
      t.integer :vat_rate_basis_points, null: false, default: 2100
      t.integer :vat_cents, null: false, default: 0
      t.integer :total_cents, null: false
      t.date :issued_on
      t.date :due_on
      t.date :paid_on
      t.string :peppol_status, null: false, default: "not_requested"
      t.string :peppol_reference
      t.string :external_reference
      t.timestamps
    end
    add_index :invoices, :number, unique: true, where: "number IS NOT NULL"
    add_index :invoices, :status

    create_table :webhook_events do |t|
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :payload_digest, null: false
      t.json :payload, null: false, default: {}
      t.string :status, null: false, default: "received"
      t.text :error_message
      t.datetime :processed_at
      t.timestamps
    end
    add_index :webhook_events, %i[provider external_id], unique: true
    add_index :webhook_events, :status
  end
end
