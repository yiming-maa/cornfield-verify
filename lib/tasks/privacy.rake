# 「后台也看不到你」部署序列（docs/plans/2026-09-03-privacy-unlinkable-verification.md）
#
#   Deploy 1  privacy:backfill_verified_emails   幂等：把存量已验证邮箱的 hash 灌进 verified_emails
#   Deploy 2  privacy:purge_email_columns        单向：profiles.uiuc_email/email_hash、verification_codes.email 全置 NULL
#   Deploy 3  （migration 删列）
namespace :privacy do
  desc "Deploy 1: backfill verified_emails from profiles (idempotent)"
  task backfill_verified_emails: :environment do
    inserted = 0
    skipped = 0
    Profile.where(is_verified: true).find_each do |profile|
      email_hash = profile.email_hash.presence || derived_hash(profile.uiuc_email)
      if email_hash.nil?
        skipped += 1
        next
      end
      VerifiedEmail.find_or_create_by!(email_hash: email_hash)
      inserted += 1
    end
    puts "verified_emails backfilled: processed=#{inserted} skipped_no_email=#{skipped} total=#{VerifiedEmail.count}"
  end

  desc "Deploy 2: NULL every plaintext/hash email column on profiles + verification_codes (CONFIRM=1 to run)"
  task purge_email_columns: :environment do
    profiles = Profile.where.not(uiuc_email: nil).or(Profile.where.not(email_hash: nil))
    codes = VerificationCode.where.not(email: nil)
    puts "would purge: profiles=#{profiles.count} verification_codes=#{codes.count}"
    unless ENV["CONFIRM"] == "1"
      puts "dry run — set CONFIRM=1 to purge. Run privacy:backfill_verified_emails first."
      next
    end

    missing = Profile.where(is_verified: true).where.not(email_hash: nil)
                     .where.not(email_hash: VerifiedEmail.select(:email_hash)).count
    raise "#{missing} verified profiles have no verified_emails row — run privacy:backfill_verified_emails first" if missing.positive?

    ActiveRecord::Base.transaction do
      profiles.update_all(uiuc_email: nil, email_hash: nil)
      codes.update_all(email: nil)
    end
    puts "purged. profiles with email now: #{Profile.where.not(uiuc_email: nil).count}"
  end

  def derived_hash(uiuc_email)
    return nil if uiuc_email.blank?
    return nil unless uiuc_email.end_with?("@illinois.edu")

    EmailHasher.hash(uiuc_email)
  end
end
