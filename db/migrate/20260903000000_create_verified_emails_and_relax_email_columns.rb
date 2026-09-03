# Deploy 1 (Expand) of docs/plans/2026-09-03-privacy-unlinkable-verification.md.
#
#   verified_emails(email_hash)  ← 无 user_id、无任何账号列
#   profiles.uiuc_email / verification_codes.email → 允许 NULL（Deploy 3 才删列）
#
# Additive-only：只加表、只放宽约束。
class CreateVerifiedEmailsAndRelaxEmailColumns < ActiveRecord::Migration[8.1]
  def up
    create_table :verified_emails, id: false do |t|
      t.text :email_hash, null: false, primary_key: true
      t.timestamptz :verified_at, null: false, default: -> { "now()" }
    end

    change_column_null :profiles, :uiuc_email, true
    change_column_null :verification_codes, :email, true

    return unless supabase_roles?

    # PostgREST 默认把 public 表暴露给 anon/authenticated；这张表只允许 Rails（service_role/owner）读写
    execute "REVOKE ALL ON TABLE public.verified_emails FROM anon, authenticated;"
    execute "ALTER TABLE public.verified_emails ENABLE ROW LEVEL SECURITY;"
  end

  def down
    change_column_null :verification_codes, :email, false
    change_column_null :profiles, :uiuc_email, false
    drop_table :verified_emails
  end

  private

  def supabase_roles?
    select_value("SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('anon', 'authenticated')").to_i == 2
  end
end
