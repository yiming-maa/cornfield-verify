require "rails_helper"

# 结构不变量：∀ table ¬(has_account_column ∧ has_email_column)
# 「数据库里没有那一行」是隐私页的承诺；这个 spec 让承诺在每次 CI 里被机器复核。
RSpec.describe "email ↔ account unlinkability", type: :model do
  ACCOUNT_COLUMN = /\A(user_id|profile_id|.*_user_id|admin_user_id)\z/
  EMAIL_COLUMN = /email/i

  # Deploy 3（remove_column）之前允许存在的遗留列。Deploy 3 后这个清单必须为空。
  LEGACY_ALLOWLIST = [
    %w[profiles uiuc_email],
    %w[profiles email_hash],
    %w[verification_codes email]
  ].freeze

  def account_column?(table, column)
    return true if table == "profiles" && column == "id"

    ACCOUNT_COLUMN.match?(column)
  end

  def violations
    conn = ActiveRecord::Base.connection
    conn.tables.flat_map do |table|
      columns = conn.columns(table).map(&:name)
      next [] unless columns.any? { |c| account_column?(table, c) }

      columns.select { |c| EMAIL_COLUMN.match?(c) }.map { |c| [ table, c ] }
    end
  end

  it "has no table that stores both an account column and an email column (outside the Deploy-3 allowlist)" do
    expect(violations - LEGACY_ALLOWLIST).to eq([])
  end

  it "keeps the allowlist honest: every listed legacy column still exists" do
    conn = ActiveRecord::Base.connection
    LEGACY_ALLOWLIST.each do |table, column|
      expect(conn.column_exists?(table, column)).to be(true), "#{table}.#{column} is gone — remove it from LEGACY_ALLOWLIST"
    end
  end

  it "verified_emails carries nothing but the hash and a timestamp" do
    expect(ActiveRecord::Base.connection.columns("verified_emails").map(&:name)).to contain_exactly("email_hash", "verified_at")
  end

  it "verified_emails has no foreign key to any table" do
    expect(ActiveRecord::Base.connection.foreign_keys("verified_emails")).to be_empty
  end
end
