RSpec.describe Holder::Handle do
  describe "#wait reaping a process group whose pgid may have been recycled" do
    it "signals the pgid off a bare liveness probe, with no ownership check" do
      # DESIRED: the group should be signalled only if it is provably still the
      # child's group. It cannot be: once the leader is reaped the kernel may
      # recycle the pgid to an unrelated group, and a group-liveness probe cannot
      # prove ownership -- an inherent hazard of addressing a group by id, as the
      # code comment notes. A design that could prove ownership would not signal.
      # CURRENT (asserted here): kill_group_leftovers signals the pgid whenever the
      # getpriority(PRIO_PGRP) probe succeeds, so a recycled group is signalled all
      # the same.
      wait_thread = reaped_wait_thread
      pid = wait_thread.pid
      allow(Process).to receive(:getpriority).and_call_original
      allow(Process).to receive(:getpriority).with(Process::PRIO_PGRP, pid).and_return(0)
      allow(Process).to receive(:kill).and_call_original
      handle = Holder::Handle.new(
        stdin: nil, stdout: nil, stderr: nil,
        wait_thread: wait_thread, pump_threads: [], owned_ios: []
      )

      handle.wait

      expect(Process).to have_received(:kill).with("-KILL", pid)
    end
  end
end
