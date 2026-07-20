RSpec.describe Clock do
  describe ".monotonic" do
    it "reads as a Float so elapsed time keeps sub-second resolution" do
      expect(described_class.monotonic).to be_a(Float)
    end

    it "never goes backwards" do
      first = described_class.monotonic

      expect(described_class.monotonic).to be >= first
    end
  end
end
