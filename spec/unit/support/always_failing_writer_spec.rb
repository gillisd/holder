RSpec.describe AlwaysFailingWriter do
  describe "#write" do
    it "raises a disk full RuntimeError so a pump takes its error path" do
      expect { described_class.new.write("data") }.to raise_error(RuntimeError, "disk full")
    end

    it "raises whatever arity the pump happens to call it with" do
      writer = described_class.new

      expect { writer.write }.to raise_error(RuntimeError)
      expect { writer.write("a", "b", "c") }.to raise_error(RuntimeError)
    end
  end
end
