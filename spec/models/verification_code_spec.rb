require "rails_helper"

RSpec.describe VerificationCode, type: :model do
  describe "validations" do
    it { is_expected.to validate_presence_of(:email_hash) }
    it { is_expected.to validate_presence_of(:code) }
    it { is_expected.to validate_presence_of(:expires_at) }
  end

  describe "scopes" do
    let!(:active_code) { create(:verification_code, expires_at: 10.minutes.from_now) }
    let!(:expired_code) { create(:verification_code, expires_at: 10.minutes.ago) }

    describe ".active" do
      it "returns only non-expired codes" do
        expect(VerificationCode.active).to contain_exactly(active_code)
      end
    end

    describe ".expired" do
      it "returns only expired codes" do
        expect(VerificationCode.expired).to contain_exactly(expired_code)
      end
    end
  end

  describe ".for_email" do
    it "finds codes by the email's hash, never by plaintext" do
      code = create(:verification_code, email: "a@illinois.edu")
      expect(VerificationCode.for_email(" A@illinois.edu")).to contain_exactly(code)
      expect(code.email).to be_nil
    end
  end

  describe "#expired?" do
    it "returns true when expires_at is in the past" do
      code = build(:verification_code, expires_at: 1.minute.ago)
      expect(code.expired?).to be true
    end

    it "returns false when expires_at is in the future" do
      code = build(:verification_code, expires_at: 1.minute.from_now)
      expect(code.expired?).to be false
    end

    it "returns true when expires_at is exactly now" do
      code = build(:verification_code, expires_at: Time.current)
      expect(code.expired?).to be true
    end
  end
end
