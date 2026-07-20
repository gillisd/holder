RSpec.describe Holder::StreamType do
  it "lives under Holder" do
    expect(Holder.constants).to include(:StreamType)
  end

  it "leaves core IO unpatched" do
    expect(IO.constants).not_to include(:InputStreamType)
  end

  # Case equality is StreamType's entire public surface -- it exists to be the
  # right-hand side of Tenant#run's `in:`/`out:`/`err:` pattern match -- so the
  # operator has to be called head-on here rather than through a stand-in.
  # rubocop:disable Style/CaseEquality
  describe ".===" do
    context "when the value is a real IO" do
      it "matches the standard streams and an opened File" do
        [$stdin, $stdout, open_tmp("w")].each do |io|
          expect(described_class).to be === io
        end
      end
    end

    context "when the value merely stands in for a stream" do
      it "rejects fd numbers, path strings, symbols and StringIO" do
        [0, 1, 2, 64, "/dev/null", "log.txt", :stdin, StringIO.new("x")].each do |value|
          expect(described_class).not_to be === value
        end
      end
    end
  end
  # rubocop:enable Style/CaseEquality
end
