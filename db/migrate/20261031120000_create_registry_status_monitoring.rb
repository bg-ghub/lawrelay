class CreateRegistryStatusMonitoring < ActiveRecord::Migration[8.1]
  def change
    create_table :registry_status_checks do |t|
      t.string :source, null: false
      t.string :target_digest, null: false
      t.string :identity_digest, null: false
      t.references :firm, foreign_key: { on_delete: :nullify }
      t.references :lawyer_profile, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.datetime :checked_at
      t.date :last_run_on
      t.string :last_definitive_status
      t.datetime :last_definitive_at
      t.string :issue_status
      t.datetime :issue_since
      t.datetime :resolved_at
      t.datetime :last_alerted_at
      t.timestamps
      t.index [ :source, :target_digest ], unique: true
      t.index [ :issue_status, :checked_at ]
    end

    create_table :registry_status_runs do |t|
      t.date :run_on, null: false
      t.string :status, null: false, default: "pending"
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :checked_count, null: false, default: 0
      t.json :checked_target_digests, null: false, default: []
      t.json :findings, null: false, default: []
      t.string :alert_status
      t.integer :alert_attempts, null: false, default: 0
      t.datetime :alert_claimed_at
      t.datetime :alert_retry_at
      t.datetime :alert_sent_at
      t.string :alert_status_reason
      t.timestamps
      t.index :run_on, unique: true
      t.index [ :status, :lease_expires_at ]
      t.index [ :alert_status, :alert_retry_at ]
    end
  end
end
