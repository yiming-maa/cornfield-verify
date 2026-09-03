class AddEmailHashToProfilesAndVerificationCodes < ActiveRecord::Migration[8.1]
  def change
    add_column :profiles, :email_hash, :text
    add_index :profiles, :email_hash, unique: true

    add_column :verification_codes, :email_hash, :text
    add_index :verification_codes, :email_hash
  end
end
