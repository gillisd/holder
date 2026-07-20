RSpec.describe Holder::Tenant do
  describe "#run" do
    context "when a stream is something that merely stands in for an IO" do
      {
        "an fd number" => { in: 0 },
        "a path string" => { out: "log.txt" },
        "a StringIO" => { err: StringIO.new },
      }.each do |stand_in, redirect|
        stream, value = redirect.first

        it "rejects #{stand_in} given as #{stream}: before a child is spawned" do
          # The rejection has to land ahead of the spawn -- that is what makes it
          # immediate. A bad stream that slipped through would leave a running
          # child behind for a pump to detonate on later, so the guarantee is
          # stated as Open3 never being reached at all.
          expect(Open3).not_to receive(:popen3)
          expect(Open3).not_to receive(:popen2)

          expect { described_class.new("cat", stream => value).run }
            .to raise_error(ArgumentError, "in:, out:, and err: must each be an IO object or nil")
        end
      end
    end
  end
end
