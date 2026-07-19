RSpec.describe Holder::Handle do
  describe "#terminate interrupted after it arms the escalation deadline" do
    it "leaves @kill_deadline set instead of clearing it" do
      # DESIRED: the escalation deadline should be cleared in an ensure, so a
      # teardown that raises partway through (here @wait_thread.join fails) does not
      # strand a stale @kill_deadline. A later teardown takes the earliest of the
      # stale deadline and its own request, so a stale, already-past deadline makes
      # that later call skip its grace and SIGKILL immediately.
      # CURRENT (asserted here): @kill_deadline = nil is the last statement before
      # the mutex block returns, so a raise before it strands the armed deadline.
      wait_thread = reaped_wait_thread
      allow(wait_thread).to receive(:join).and_raise(RuntimeError, "wait thread died")
      handle = Holder::Handle.new(
        stdin: nil, stdout: nil, stderr: nil,
        wait_thread: wait_thread, pump_threads: [], owned_ios: []
      )

      expect { handle.terminate(grace: 0.5) }.to raise_error(RuntimeError, "wait thread died")
      expect(handle.instance_variable_get(:@kill_deadline)).not_to be_nil
    end
  end
end
