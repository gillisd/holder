RSpec.describe "waiting on a child whose out: sink only starts draining after a teardown would have given up" do
  let(:reader_and_writer) { make_pipe }
  let(:reader) { reader_and_writer.first }
  let(:writer) { reader_and_writer.last }

  before { fill_pipe(writer) }

  # Sit past the teardown drain bound: if wait deadline-killed the pump the
  # way terminate does, the child's 8 KiB would be lost by now.
  def wait_left_sitting_past_pump_grace
    handle = spawn_process("dd", "if=/dev/zero", "bs=512", "count=16", out: writer)
    Thread.new { handle.wait }.tap { sleep Holder::Handle::PUMP_GRACE + 0.4 }
  end

  # Scripted delay alone is PUMP_GRACE + 0.4 plus a drain window of up to 1s,
  # which leaves the 3s tier budget too little slack on a loaded runner. The
  # budget is sized to that work instead, and the promptness it used to bound
  # implicitly -- wait must not linger once the sink has drained -- is asserted
  # outright below. Both facets are read off one staged child rather than
  # spawning and sitting out PUMP_GRACE twice.
  it "delivers every byte the child wrote, then returns", :aggregate_failures, timeout: 8 do
    waiter = wait_left_sitting_past_pump_grace
    zeros = drain_zero_bytes(reader, 8192, deadline: Clock.monotonic + 1)

    expect(elapsed { waiter.join }).to be < 1
    expect(zeros).to eq(8192)
  end
end
