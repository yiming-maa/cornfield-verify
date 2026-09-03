class VerificationCode < ApplicationRecord
  validates :email_hash, presence: true
  validates :code, presence: true
  validates :expires_at, presence: true

  scope :active, -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :for_email, ->(email) { where(email_hash: EmailHasher.hash(email)) }

  def expired?
    expires_at <= Time.current
  end
end
