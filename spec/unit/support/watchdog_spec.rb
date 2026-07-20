RSpec.describe Watchdog do
  describe ".budget" do
    it "gives an integration example the hang-catcher default" do
      expect(described_class.budget({ tier: :integration })).to eq(described_class::INTEGRATION)
    end

    it "lets an integration example state a heavier budget for its own churn" do
      expect(described_class.budget({ tier: :integration, timeout: 20 })).to eq(20)
    end

    it "holds a unit example to the fast floor" do
      expect(described_class.budget({ tier: :unit })).to eq(described_class::FAST)
    end

    it "refuses to let a unit example raise itself past the fast floor" do
      # The floor is what keeps the fast tier fast: an example that wants longer
      # is an integration example living in the wrong directory.
      expect(described_class.budget({ tier: :unit, timeout: 30 })).to eq(described_class::FAST)
    end

    it "lets a unit example lower its own budget" do
      expect(described_class.budget({ tier: :unit, timeout: 0.5 })).to eq(0.5)
    end
  end
end
