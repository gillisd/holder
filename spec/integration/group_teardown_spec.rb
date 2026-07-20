RSpec.describe "tearing down a process group" do
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
    end

    context "when a grandchild traps TERM to shut down cleanly and the leader has already exited" do
      # The grandchild traps TERM to shut down cleanly (write the marker), then
      # prints its pid only AFTER the trap is installed -- so reading the pid means
      # terminate can't race ahead of the trap. It idles by blocking in-process on
      # the fifo rather than a forked `sleep`, so teardown's TERM is delivered
      # straight to the trap and can't be lost racing a `sleep` mid fork/exec.
      let(:marker) { tmpfile }
      let(:cooperative_shutdown) do
        %(trap "sleep 0.3; echo done > #{marker}; exit 0" TERM; echo $$; read _ <> #{blocking_fifo})
      end
      let(:handle) { spawn_process("sh", "-c", %(sh -c '#{cooperative_shutdown}' &)) }
      let!(:grandchild) { live_pid_from(handle.stdout) }

      before do
        wait_for_exit(handle.pid)
        handle.terminate(grace: 1)
      end

      # One staged shutdown, two facets of the same contract: re-spawning the
      # grandchild per expectation would pay for its full grace window twice.
      it "grants it the grace to finish and still collects it", :aggregate_failures do
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
