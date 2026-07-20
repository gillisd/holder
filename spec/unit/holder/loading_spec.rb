RSpec.describe Holder do
  describe "VERSION" do
    it "is published by the gem" do
      expect(Holder::VERSION).not_to be_nil
    end
  end

  describe "LOADER" do
    it "eager-loads every constant under lib/holder without a naming violation" do
      # force: true so the load runs even after an earlier eager_load in the same
      # process: this is the guard that a misnamed or misplaced file under
      # lib/holder/ fails the suite rather than lying dormant behind an autoload
      # nobody in the suite happens to touch.
      expect { Holder::LOADER.eager_load(force: true) }.not_to raise_error

      expect(Holder::LOADER).to be_a(Zeitwerk::Loader)
    end
  end
end
