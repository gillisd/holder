RSpec.describe AlwaysFailingWriter do
  subject(:writer) { described_class.new }

  describe "#write" do
    it "raises a disk full RuntimeError so a pump takes its error path" do
      expect { writer.write("data") }.to raise_error(RuntimeError, "disk full")
    end

    # A pump may call #write with any arity, so none of them may be answered by
    # an ArgumentError instead of the failure the pump is being staged to hit.
    it "raises when called with no arguments" do
      expect { writer.write }.to raise_error(RuntimeError)
    end

    it "raises when called with more arguments than one" do
      expect { writer.write("a", "b", "c") }.to raise_error(RuntimeError)
    end
  end
end
