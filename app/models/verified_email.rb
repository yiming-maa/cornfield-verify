# 「已验证过的 UIUC 邮箱」集合。只有 email_hash，没有 user_id——数据库里不存在任何一行
# 能把邮箱和账号连起来。这是隐私承诺的物理基础，见 spec/db/unlinkability_spec.rb。
class VerifiedEmail < ApplicationRecord
  self.primary_key = "email_hash"

  validates :email_hash, presence: true

  def self.verified?(email)
    exists?(email_hash: EmailHasher.hash(email))
  end
end
