RSpec.describe "bounding a wait whose out: sink refuses to drain" do
  # Budgets sized to the scripted drain windows rather than the tier default:
  # each example deliberately sits out a WAIT_DRAIN_GRACE. Nothing is lost by
  # that -- the bound each example actually asserts is the explicit
  # Timeout.timeout inside it, not the watchdog.
  describe "a sink that can never accept the child's output", timeout: 8 do
    let(:reader_and_writer) { make_pipe }
    let(:writer) { reader_and_writer.last }

    before { fill_pipe(writer) }

    it "returns instead of blocking forever on the wedged drain" do
      handle = spawn_process("sh", "-c", "echo blocked", out: writer)

      expect { Timeout.timeout(3) { handle.wait } }.not_to raise_error
    end

    it "surfaces the discarded output as a StalledSinkError in pump_error" do
      handle = spawn_process("sh", "-c", "echo blocked", out: writer)
      Timeout.timeout(3) { handle.wait }

      expect(handle.pump_error).to be_a(Holder::StalledSinkError)
    end

    it "cuts the drain sooner for a caller with a tighter drain_grace" do
      handle = spawn_process("sh", "-c", "echo blocked", out: writer)

      expect { Timeout.timeout(1) { handle.wait(drain_grace: 0.2) } }.not_to raise_error
    end
  end

  describe "a sink that drains, but slower than the default bound", timeout: 12 do
    let(:reader_and_writer) { make_pipe }
    let(:reader) { reader_and_writer.first }
    let(:writer) { reader_and_writer.last }
    let(:handle) { spawn_process("sh", "-c", "echo blocked", out: writer) }

    # Thread.new takes the handle as an argument so the child is spawned on the
    # example's own thread, before the drain window opens.
    let(:waiter) { Thread.new(handle) { |wedged| wedged.wait(drain_grace: 30) } }

    before do
      fill_pipe(writer)
      waiter.join(Holder::Handle::WAIT_DRAIN_GRACE + 0.4)
    end

    it "delivers everything under a raised drain_grace instead of truncating", :aggregate_failures do
      expect(waiter).to be_alive
      delivered = drain_until(reader, "blocked")
      waiter.join
      expect(delivered).to include("blocked")
      expect(handle.pump_error).to be_nil
    end
  end
end
