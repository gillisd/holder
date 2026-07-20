RSpec.describe Holder::Handle do
  describe "#terminate" do
    it "kills a grandchild the leader backgrounded" do
      handle = spawn_process("sh", "-c", "sleep #{outlives_example} & echo $!; sleep #{outlives_example}")
      grandchild = live_pid_from(handle.stdout)
      handle.terminate(grace: 0.5)

      expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
    end

    context "when the leader has already exited" do
      it "still signals the rest of the group" do
        handle = spawn_process("sh", "-c", "sleep #{outlives_example} & echo $!")
        grandchild = live_pid_from(handle.stdout)
        wait_for_exit(handle.pid)
        handle.terminate(grace: 0.5)

        expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
      end

      it "force kills a grandchild that ignores TERM" do
        handle = spawn_process("sh", "-c", "trap '' TERM; sleep #{outlives_example} & echo $!")
        grandchild = live_pid_from(handle.stdout)
        wait_for_exit(handle.pid)
        handle.terminate(grace: 0.5)

        expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
      end

      it "grants a cooperative grandchild its grace to shut down cleanly" do
        marker = tmpfile
        fifo = blocking_fifo
        # The grandchild traps TERM to shut down cleanly (write the marker), then
        # prints its pid only AFTER the trap is installed -- so reading the pid means
        # terminate can't race ahead of the trap. It idles by blocking in-process on
        # the fifo rather than a forked `sleep`, so teardown's TERM is delivered
        # straight to the trap and can't be lost racing a `sleep` mid fork/exec.
        body = %(trap "sleep 0.3; echo done > #{marker}; exit 0" TERM; echo $$; read _ <> #{fifo})
        handle = spawn_process("sh", "-c", %(sh -c '#{body}' &))
        grandchild = live_pid_from(handle.stdout)
        wait_for_exit(handle.pid)
        handle.terminate(grace: 1)

        expect(File).to exist(marker)
        expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
      end
    end
  end

  describe "#interrupt" do
    context "when the leader has already exited" do
      it "force kills a grandchild that ignores INT" do
        # a non-interactive shell already sets INT to SIG_IGN for `&` jobs, so the
        # backgrounded sleep ignores the interrupt; teardown must escalate to KILL
        handle = spawn_process("sh", "-c", "sleep #{outlives_example} & echo $!")
        grandchild = live_pid_from(handle.stdout)
        wait_for_exit(handle.pid)
        handle.interrupt(grace: 0.5)

        expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
      end
    end
  end

  describe "#wait" do
    it "reaps the rest of the group after the leader exits" do
      handle = spawn_process("sh", "-c", "sleep #{outlives_example} & echo $!")
      grandchild = live_pid_from(handle.stdout)
      handle.wait

      expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
    end
  end
end

RSpec.describe Holder::Tenant do
  describe "#run given a user-supplied pgroup: override" do
    it "still tears down a grandchild the leader backgrounded" do
      # The group is the unit of teardown, so pgroup: is never overridable: the
      # child leads its own group no matter what the caller passes.
      idle_with_backgrounded_child = "sleep #{outlives_example} & echo $!; sleep #{outlives_example}"
      handle = spawn_process("sh", "-c", idle_with_backgrounded_child, pgroup: false)
      grandchild = live_pid_from(handle.stdout)
      handle.terminate(grace: 0.5)

      expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
    end
  end
end
