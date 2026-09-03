FactoryBot.define do
  factory :verification_code do
    transient do
      email { Faker::Internet.email(domain: "illinois.edu") }
    end

    email_hash { EmailHasher.hash(email) }
    code { SecureRandom.random_number(100_000..999_999).to_s }
    expires_at { 10.minutes.from_now }
  end

  factory :verified_email do
    transient do
      email { Faker::Internet.email(domain: "illinois.edu") }
    end

    email_hash { EmailHasher.hash(email) }
  end
end
