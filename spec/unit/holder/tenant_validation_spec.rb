RSpec.describe Holder::Tenant do
  describe "#run" do
    shared_examples "a stream that merely stands in for an IO" do
      let(:tenant) { described_class.new("cat", **redirect) }

      before do
        allow(Open3).to receive(:popen3)
        allow(Open3).to receive(:popen2)
      end

      it "is rejected with an ArgumentError" do
        expect { tenant.run }
          .to raise_error(ArgumentError, "in:, out:, and err: must each be an IO object or nil")
      end

      # The rejection has to land ahead of the spawn -- that is what makes it
      # immediate. A bad stream that slipped through would leave a running
      # child behind for a pump to detonate on later, so the guarantee is
      # stated as Open3 never being reached at all.
      it "is rejected before Open3.popen3 can spawn a child" do
        attempt_run

        expect(Open3).not_to have_received(:popen3)
      end

      it "is rejected before Open3.popen2 can spawn a child" do
        attempt_run

        expect(Open3).not_to have_received(:popen2)
      end

      def attempt_run
        tenant.run
      rescue ArgumentError
        nil
      end
    end

    context "when in: is an fd number" do
      let(:redirect) { { in: 0 } }

      it_behaves_like "a stream that merely stands in for an IO"
    end

    context "when out: is a path string" do
      let(:redirect) { { out: "log.txt" } }

      it_behaves_like "a stream that merely stands in for an IO"
    end

    context "when err: is a StringIO" do
      let(:redirect) { { err: StringIO.new } }

      it_behaves_like "a stream that merely stands in for an IO"
    end
  end
end
