RSpec.describe Holder do
  describe "VERSION" do
    it "is published by the gem" do
      expect(described_class::VERSION).not_to be_nil
    end
  end

  describe "LOADER" do
    it "is the Zeitwerk loader that owns the gem's constants" do
      expect(described_class::LOADER).to be_a(Zeitwerk::Loader)
    end

    # force: true so the load runs even after an earlier eager_load in the same
    # process: this is the guard that a misnamed or misplaced file under
    # lib/holder/ fails the suite rather than lying dormant behind an autoload
    # nobody in the suite happens to touch.
    it "eager-loads every constant under lib/holder without a naming violation" do
      expect { described_class::LOADER.eager_load(force: true) }.not_to raise_error
    end
  end
end
