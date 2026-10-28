# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_28_110001) do
  create_table "assignments", force: :cascade do |t|
    t.string "kind", default: "court_replacement", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.string "court"
    t.string "city"
    t.datetime "starts_at", null: false
    t.integer "duration_minutes", default: 60, null: false
    t.string "practice_area", null: false
    t.integer "fee_cents"
    t.string "status", default: "open", null: false
    t.boolean "urgent", default: false, null: false
    t.string "languages"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "creator_user_id"
    t.integer "firm_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "content_rules_accepted_at"
    t.string "assignment_subtype"
    t.datetime "response_deadline_at"
    t.string "scope_indication"
    t.datetime "delivery_due_at"
    t.index ["city"], name: "index_assignments_on_city"
    t.index ["creator_user_id"], name: "index_assignments_on_creator_user_id"
    t.index ["firm_id"], name: "index_assignments_on_firm_id"
    t.index ["kind"], name: "index_assignments_on_kind"
    t.index ["practice_area"], name: "index_assignments_on_practice_area"
    t.index ["response_deadline_at"], name: "index_assignments_on_response_deadline_at"
    t.index ["starts_at"], name: "index_assignments_on_starts_at"
    t.index ["status"], name: "index_assignments_on_status"
  end

  create_table "audit_events", force: :cascade do |t|
    t.integer "actor_user_id"
    t.integer "firm_id"
    t.string "auditable_type", null: false
    t.integer "auditable_id", null: false
    t.string "action", null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["actor_user_id"], name: "index_audit_events_on_actor_user_id"
    t.index ["auditable_type", "auditable_id", "created_at"], name: "index_audit_events_on_subject_and_time"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_events_on_auditable"
    t.index ["firm_id"], name: "index_audit_events_on_firm_id"
  end

  create_table "billing_accounts", force: :cascade do |t|
    t.integer "firm_id", null: false
    t.string "provider", default: "manual", null: false
    t.string "provider_customer_id"
    t.string "billing_email"
    t.string "peppol_id"
    t.string "plan_key", default: "founding_beta", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "complimentary_access_until"
    t.index ["firm_id"], name: "index_billing_accounts_on_firm_id", unique: true
    t.index ["provider", "provider_customer_id"], name: "index_billing_accounts_on_provider_customer", unique: true, where: "provider_customer_id IS NOT NULL"
  end

  create_table "billing_payments", force: :cascade do |t|
    t.integer "billing_account_id", null: false
    t.integer "subscription_id"
    t.string "provider", default: "manual", null: false
    t.string "provider_payment_id"
    t.string "status", default: "pending", null: false
    t.integer "amount_cents", null: false
    t.string "currency", default: "EUR", null: false
    t.string "idempotency_key", null: false
    t.datetime "paid_at"
    t.datetime "refunded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["billing_account_id"], name: "index_billing_payments_on_billing_account_id"
    t.index ["idempotency_key"], name: "index_billing_payments_on_idempotency_key", unique: true
    t.index ["provider", "provider_payment_id"], name: "index_billing_payments_on_provider_payment", unique: true, where: "provider_payment_id IS NOT NULL"
    t.index ["status"], name: "index_billing_payments_on_status"
    t.index ["subscription_id"], name: "index_billing_payments_on_subscription_id"
  end

  create_table "firms", force: :cascade do |t|
    t.string "name", null: false
    t.string "enterprise_number"
    t.string "vat_number"
    t.string "billing_email"
    t.string "phone"
    t.string "address_line_1"
    t.string "postal_code"
    t.string "city"
    t.string "country_code", default: "BE", null: false
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["enterprise_number"], name: "index_firms_on_enterprise_number", unique: true, where: "enterprise_number IS NOT NULL"
    t.index ["vat_number"], name: "index_firms_on_vat_number", unique: true, where: "vat_number IS NOT NULL"
    t.index ["verification_status"], name: "index_firms_on_verification_status"
  end

  create_table "invoices", force: :cascade do |t|
    t.integer "billing_account_id", null: false
    t.integer "subscription_id"
    t.string "number"
    t.string "status", default: "draft", null: false
    t.string "currency", default: "EUR", null: false
    t.integer "subtotal_cents", null: false
    t.integer "vat_rate_basis_points", default: 2100, null: false
    t.integer "vat_cents", default: 0, null: false
    t.integer "total_cents", null: false
    t.date "issued_on"
    t.date "due_on"
    t.date "paid_on"
    t.string "peppol_status", default: "not_requested", null: false
    t.string "peppol_reference"
    t.string "external_reference"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["billing_account_id"], name: "index_invoices_on_billing_account_id"
    t.index ["number"], name: "index_invoices_on_number", unique: true, where: "number IS NOT NULL"
    t.index ["status"], name: "index_invoices_on_status"
    t.index ["subscription_id"], name: "index_invoices_on_subscription_id"
  end

  create_table "lawyer_profiles", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "bar_association", null: false
    t.string "bar_number", null: false
    t.string "professional_email"
    t.json "spoken_languages", default: [], null: false
    t.json "practice_areas", default: [], null: false
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.text "verification_note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "bar_admission_year"
    t.json "court_preferences", default: [], null: false
    t.string "availability_note"
    t.string "directory_profile_url"
    t.string "directory_profile_id"
    t.string "directory_name"
    t.string "directory_email"
    t.datetime "directory_checked_at"
    t.datetime "directory_email_verified_at"
    t.datetime "directory_confirmation_requested_at"
    t.string "directory_identity_digest"
    t.index ["bar_association", "bar_number"], name: "index_lawyer_profiles_on_bar_association_and_bar_number", unique: true
    t.index ["directory_profile_id"], name: "index_lawyer_profiles_on_directory_profile_id", unique: true, where: "directory_profile_id IS NOT NULL AND directory_email_verified_at IS NOT NULL"
    t.index ["user_id"], name: "index_lawyer_profiles_on_user_id", unique: true
    t.index ["verification_status"], name: "index_lawyer_profiles_on_verification_status"
  end

  create_table "memberships", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "firm_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["firm_id"], name: "index_memberships_on_firm_id"
    t.index ["user_id", "firm_id"], name: "index_memberships_on_user_id_and_firm_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "subject_type"
    t.integer "subject_id"
    t.string "kind", null: false
    t.json "data", default: {}, null: false
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id"], name: "index_notifications_on_subject"
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "privacy_requests", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "kind", null: false
    t.string "status", default: "pending", null: false
    t.text "details", null: false
    t.integer "handled_by_user_id"
    t.text "resolution_note"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["handled_by_user_id"], name: "index_privacy_requests_on_handled_by_user_id"
    t.index ["status", "created_at"], name: "index_privacy_requests_on_status_and_created_at"
    t.index ["user_id"], name: "index_privacy_requests_on_user_id"
  end

  create_table "proposals", force: :cascade do |t|
    t.integer "assignment_id", null: false
    t.string "name"
    t.string "email"
    t.integer "rate_cents", null: false
    t.text "message", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.integer "firm_id"
    t.datetime "accepted_at"
    t.datetime "declined_at"
    t.datetime "withdrawn_at"
    t.string "rate_kind", default: "fixed", null: false
    t.index ["assignment_id", "user_id"], name: "index_proposals_on_assignment_id_and_user_id", unique: true, where: "user_id IS NOT NULL"
    t.index ["assignment_id"], name: "index_proposals_on_assignment_id"
    t.index ["assignment_id"], name: "index_proposals_on_one_accepted_per_assignment", unique: true, where: "status = 'accepted'"
    t.index ["firm_id"], name: "index_proposals_on_firm_id"
    t.index ["status"], name: "index_proposals_on_status"
    t.index ["user_id"], name: "index_proposals_on_user_id"
  end

  create_table "reports", force: :cascade do |t|
    t.integer "reporter_user_id", null: false
    t.string "reportable_type", null: false
    t.integer "reportable_id", null: false
    t.string "category", null: false
    t.string "status", default: "open", null: false
    t.text "details", null: false
    t.integer "reviewed_by_user_id"
    t.text "resolution_note"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reportable_type", "reportable_id"], name: "index_reports_on_reportable"
    t.index ["reporter_user_id"], name: "index_reports_on_reporter_user_id"
    t.index ["reviewed_by_user_id"], name: "index_reports_on_reviewed_by_user_id"
    t.index ["status", "created_at"], name: "index_reports_on_status_and_created_at"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_seen_at"
    t.datetime "admin_mfa_verified_at"
    t.datetime "admin_mfa_challenged_at"
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.integer "billing_account_id", null: false
    t.string "provider", default: "manual", null: false
    t.string "provider_subscription_id"
    t.string "plan_key", default: "lawrelay_office", null: false
    t.string "status", default: "trialing", null: false
    t.integer "amount_cents", default: 4900, null: false
    t.string "currency", default: "EUR", null: false
    t.string "interval", default: "month", null: false
    t.string "idempotency_key", null: false
    t.datetime "starts_at"
    t.datetime "current_period_ends_at"
    t.datetime "cancelled_at"
    t.datetime "suspended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["billing_account_id"], name: "index_subscriptions_on_billing_account_id"
    t.index ["idempotency_key"], name: "index_subscriptions_on_idempotency_key", unique: true
    t.index ["provider", "provider_subscription_id"], name: "index_subscriptions_on_provider_subscription", unique: true, where: "provider_subscription_id IS NOT NULL"
    t.index ["status"], name: "index_subscriptions_on_status"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "first_name", default: "", null: false
    t.string "last_name", default: "", null: false
    t.string "locale", default: "nl", null: false
    t.string "system_role", default: "member", null: false
    t.datetime "email_verified_at"
    t.datetime "accepted_terms_at"
    t.string "accepted_terms_version"
    t.string "accepted_privacy_version"
    t.string "admin_mfa_secret_ciphertext"
    t.string "admin_mfa_pending_secret_ciphertext"
    t.datetime "admin_mfa_enabled_at"
    t.datetime "admin_mfa_last_verified_at"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "webhook_events", force: :cascade do |t|
    t.string "provider", null: false
    t.string "external_id", null: false
    t.string "payload_digest", null: false
    t.json "payload", default: {}, null: false
    t.string "status", default: "received", null: false
    t.text "error_message"
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "external_id"], name: "index_webhook_events_on_provider_and_external_id", unique: true
    t.index ["status"], name: "index_webhook_events_on_status"
  end

  add_foreign_key "assignments", "firms"
  add_foreign_key "assignments", "users", column: "creator_user_id"
  add_foreign_key "audit_events", "firms"
  add_foreign_key "audit_events", "users", column: "actor_user_id"
  add_foreign_key "billing_accounts", "firms"
  add_foreign_key "billing_payments", "billing_accounts"
  add_foreign_key "billing_payments", "subscriptions"
  add_foreign_key "invoices", "billing_accounts"
  add_foreign_key "invoices", "subscriptions"
  add_foreign_key "lawyer_profiles", "users"
  add_foreign_key "memberships", "firms"
  add_foreign_key "memberships", "users"
  add_foreign_key "notifications", "users"
  add_foreign_key "privacy_requests", "users"
  add_foreign_key "privacy_requests", "users", column: "handled_by_user_id"
  add_foreign_key "proposals", "assignments"
  add_foreign_key "proposals", "firms"
  add_foreign_key "proposals", "users"
  add_foreign_key "reports", "users", column: "reporter_user_id"
  add_foreign_key "reports", "users", column: "reviewed_by_user_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "subscriptions", "billing_accounts"
end
