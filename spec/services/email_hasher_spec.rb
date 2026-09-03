require "rails_helper"

RSpec.describe EmailHasher do
  describe ".hash" do
    it "is deterministic for the same email" do
      expect(described_class.hash("a@illinois.edu")).to eq(described_class.hash("a@illinois.edu"))
    end

    it "normalizes case and whitespace before hashing" do
      expect(described_class.hash("  A@Illinois.EDU ")).to eq(described_class.hash("a@illinois.edu"))
    end

    it "produces different hashes for different emails" do
      expect(described_class.hash("a@illinois.edu")).not_to eq(described_class.hash("b@illinois.edu"))
    end

    it "returns a 64-char hex digest" do
      expect(described_class.hash("a@illinois.edu")).to match(/\A[0-9a-f]{64}\z/)
    end

    it "depends on the pepper" do
      h1 = described_class.hash("a@illinois.edu")
      allow(ENV).to receive(:[]).with("EMAIL_HASH_PEPPER").and_return("another-pepper")
      expect(described_class.hash("a@illinois.edu")).not_to eq(h1)
    end
  end

  describe ".pepper" do
    it "raises MissingPepperError in production when EMAIL_HASH_PEPPER is unset" do
      allow(ENV).to receive(:[]).with("EMAIL_HASH_PEPPER").and_return(nil)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { described_class.pepper }.to raise_error(EmailHasher::MissingPepperError)
    end

    it "falls back to a dev pepper outside production" do
      allow(ENV).to receive(:[]).with("EMAIL_HASH_PEPPER").and_return(nil)
      expect(described_class.pepper).to include("insecure-dev-pepper")
    end
  end
end
