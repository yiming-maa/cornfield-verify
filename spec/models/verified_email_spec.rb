require "rails_helper"

RSpec.describe VerifiedEmail, type: :model do
  it { is_expected.to validate_presence_of(:email_hash) }

  describe ".verified?" do
    it "is true once the email's hash is stored" do
      create(:verified_email, email: "a@illinois.edu")
      expect(described_class.verified?("A@Illinois.edu ")).to be true
    end

    it "is false for an unknown email" do
      expect(described_class.verified?("nobody@illinois.edu")).to be false
    end
  end

  it "rejects a duplicate hash at the database level" do
    create(:verified_email, email: "a@illinois.edu")
    expect { described_class.create!(email_hash: EmailHasher.hash("a@illinois.edu")) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
