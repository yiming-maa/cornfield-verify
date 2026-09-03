# Deterministic keyed hash for email addresses (HMAC-SHA256 + secret pepper).
# Only equality is needed (verified_emails membership, code lookup). Reversing a
# hash requires the pepper, so a DB leak alone cannot enumerate the small
# @illinois.edu address space. Even with the pepper, a hash maps to "this email
# has verified" — never to an account, because no table stores both.
class EmailHasher
  class MissingPepperError < StandardError; end

  DIGEST = "SHA256"

  def self.hash(email)
    OpenSSL::HMAC.hexdigest(DIGEST, pepper, normalize(email))
  end

  def self.normalize(email)
    email.to_s.strip.downcase
  end

  def self.pepper
    value = ENV["EMAIL_HASH_PEPPER"]
    return value if value.present?
    raise MissingPepperError, "EMAIL_HASH_PEPPER is not set" if Rails.env.production?

    "insecure-dev-pepper-#{Rails.env}"
  end
end
