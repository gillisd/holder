RSpec.describe Holder::Handle do
  describe "#terminate interrupted after it arms the escalation deadline" do
    it "leaves @kill_deadline set instead of clearing it" do
      # DESIRED: the escalation deadline should be cleared in an ensure, so a
      # teardown interrupted partway through does not strand a stale @kill_deadline.
      # A later teardown takes the earliest of the stale deadline and its own
      # request, so a stale, already-past deadline makes that later call skip its
      # grace and SIGKILL immediately.
      # CURRENT (asserted here): @kill_deadline = nil is the last statement before
      # the mutex block returns, so an interruption before it strands the deadline.
      handle = spawn_process("sh", "-c", 'trap "" TERM; echo ready; exec sleep 300')
      handle.stdout.gets
      terminating = Thread.new { handle.terminate(grace: 5) }
      terminating.report_on_exception = false
      sleep 0.3
      terminating.raise(Interrupt)
      Thread.pass while terminating.alive?

      expect(handle.instance_variable_get(:@kill_deadline)).not_to be_nil
    end
  end
end
