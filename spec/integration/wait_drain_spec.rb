RSpec.describe Holder::Handle do
  describe "#wait when the redirected out: sink only starts draining after a teardown would have given up" do
    let(:reader_and_writer) { make_pipe }
    let(:reader) { reader_and_writer.first }
    let(:writer) { reader_and_writer.last }

    before { fill_pipe(writer) }

    # Scripted delay alone is PUMP_GRACE + 0.4 plus a drain window of up to 1s,
    # which leaves the 3s tier budget too little slack on a loaded runner. The
    # budget is sized to that work instead, and the promptness it used to bound
    # implicitly -- wait must not linger once the sink has drained -- is asserted
    # outright below.
    it "delivers every byte the child wrote, then returns", timeout: 8 do
      handle = spawn_process("dd", "if=/dev/zero", "bs=512", "count=16", out: writer)
      waiter = Thread.new { handle.wait }
      # Sit past the teardown drain bound: if wait deadline-killed the pump the
      # way terminate does, the child's 8 KiB would be lost by now.
      sleep Holder::Handle::PUMP_GRACE + 0.4
      zeros = drain_zero_bytes(reader, 8192, deadline: Clock.monotonic + 1)

      expect(elapsed { waiter.join }).to be < 1
      expect(zeros).to eq(8192)
    end
  end
end
