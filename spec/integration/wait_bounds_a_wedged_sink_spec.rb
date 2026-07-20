RSpec.describe Holder::Handle do
  describe "#wait when the redirected out: sink can never accept the child's output" do
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

  describe "#wait when the redirected out: sink drains, but slower than the default bound" do
    let(:reader_and_writer) { make_pipe }
    let(:reader) { reader_and_writer.first }
    let(:writer) { reader_and_writer.last }

    before { fill_pipe(writer) }

    it "delivers everything under a raised drain_grace instead of truncating", :aggregate_failures do
      handle = spawn_process("sh", "-c", "echo blocked", out: writer)
      waiter = Thread.new { handle.wait(drain_grace: 30) }
      sleep Holder::Handle::WAIT_DRAIN_GRACE + 0.4
      expect(waiter).to be_alive

      delivered = drain_until(reader, "blocked")
      waiter.join
      expect(delivered).to include("blocked")
      expect(handle.pump_error).to be_nil
    end
  end
end
