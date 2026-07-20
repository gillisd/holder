RSpec.describe Cleanup do
  subject(:cleanup) { described_class.new }

  let(:removed_paths) { [] }
  let(:signals_sent) { [] }

  # Both stubs pin the call signature as well as the arguments: an extra
  # argument (FileUtils.remove_entry(path, force) or a three-arg Process.kill)
  # matches no stub and fails the example, the way the strict lambdas these
  # replaced did. A bare receive(:kill) would swallow the arity change.
  before do
    allow(FileUtils).to receive(:remove_entry).with(String) do |path|
      removed_paths << path
    end
    allow(Process).to receive(:kill).with(String, Integer) do |signal, pid|
      signals_sent << [signal, pid]
    end
  end

  describe "#run" do
    it "undoes the deferred actions in reverse order" do
      cleanup.path("first")
      cleanup.path("second")

      cleanup.run

      expect(removed_paths).to eq(["second", "first"])
    end

    context "when one deferred action hangs instead of raising" do
      # The teardown a wedged example leaves behind is the one most likely to
      # hang: a handle whose terminate is exactly what went wrong. Bounding only
      # raising actions would let that strand every action registered beneath it,
      # and the example's own watchdog cannot help -- it has already fired.
      subject(:cleanup) { described_class.new(action_grace: 0.05) }

      it "gives up on it and undoes the rest anyway" do
        cleanup.path("beneath")
        cleanup.instance_eval { defer { sleep 30 } }

        cleanup.run

        expect(removed_paths).to eq(["beneath"])
      end
    end

    context "when one deferred action raises" do
      # Teardown is best-effort: a pid already reaped, an IO already closed or a
      # path already gone must never strand the actions registered beneath it.
      before do
        allow(FileUtils).to receive(:remove_entry).with(String) do |path|
          raise "boom" if path == "explode"

          removed_paths << path
        end
      end

      it "keeps undoing the rest" do
        cleanup.path("bottom")
        cleanup.path("explode")
        cleanup.path("top")

        cleanup.run

        expect(removed_paths).to eq(["top", "bottom"])
      end
    end
  end

  describe "#process" do
    it "returns the handle it registered" do
      # A bare object, not a double: registering must return the handle without
      # touching it, and an object with no #terminate at all proves that.
      handle = Object.new

      expect(cleanup.process(handle)).to be(handle)
    end

    it "terminates the handle on run" do
      handle = instance_double(Holder::Handle, terminate: nil)
      cleanup.process(handle)

      cleanup.run

      expect(handle).to have_received(:terminate).with(grace: 0.2)
    end
  end

  describe "#pid" do
    it "returns the pid coerced to an integer" do
      expect(cleanup.pid("123")).to eq(123)
    end

    it "kills a positive pid on run" do
      cleanup.pid(123)

      cleanup.run

      expect(signals_sent).to eq([["KILL", 123]])
    end

    it "signals the whole group when group is true" do
      cleanup.pid(123, group: true)

      cleanup.run

      expect(signals_sent).to eq([["-KILL", 123]])
    end

    it "never signals a nonpositive pid" do
      # Zero and negative pids address this process's own group, so they are
      # dropped at registration rather than fired at teardown.
      cleanup.pid(0)
      cleanup.pid(-5)

      cleanup.run

      expect(signals_sent).to be_empty
    end
  end

  describe "#io" do
    it "returns the io it registered" do
      io = StringIO.new("data")

      expect(cleanup.io(io)).to be(io)
    end

    it "closes the io on run" do
      io = StringIO.new("data")
      cleanup.io(io)

      cleanup.run

      expect(io).to be_closed
    end
  end

  describe "#path" do
    it "returns the path it registered" do
      expect(cleanup.path("/tmp/holder_x")).to eq("/tmp/holder_x")
    end

    it "removes the path on run" do
      cleanup.path("/tmp/holder_x")

      cleanup.run

      expect(removed_paths).to eq(["/tmp/holder_x"])
    end
  end
end
