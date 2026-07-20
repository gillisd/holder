RSpec.describe "choosing the first signal a child is torn down with" do
  describe "#terminate" do
    it "returns a status for a child that has already exited" do
      handle = spawn_process("true")
      wait_for_exit(handle.pid)

      expect(handle.terminate).to be_a(Process::Status)
    end

    it "delivers TERM as the first signal when the child cooperates" do
      # sleep is spawned directly -- no shell. A shell in front can catch a group
      # signal during its own fork window and drop it on the floor, which is a
      # shell quirk, not the teardown behavior under test.
      handle = spawn_process("sleep", outlives_example.to_s)

      expect(handle.terminate(grace: 5).termsig).to eq(Signal.list["TERM"])
    end

    it "returns the same status when called a second time" do
      handle = spawn_process("sh", "-c", "sleep #{outlives_example}")
      first = handle.terminate(grace: 0.5)

      expect(handle.terminate(grace: 0.5)).to be(first)
    end

    it "closes the handle's pipes" do
      handle = spawn_process("sh", "-c", "sleep #{outlives_example}")
      handle.terminate(grace: 0.5)

      expect([handle.stdin, handle.stdout, handle.stderr]).to all(be_closed)
    end

    context "when the child ignores TERM" do
      it "force kills it once the grace window closes" do
        handle = spawn_process("sh", "-c", 'trap "" TERM; while :; do sleep 1; done')
        pid = handle.pid
        handle.terminate(grace: 0.5)

        expect(ProcessProbe.new(pid)).not_to be_alive
      end
    end
  end

  describe "#interrupt" do
    it "delivers INT as the first signal when the child cooperates" do
      # sleep is spawned directly -- no shell. A shell in front can catch a group
      # INT during its own fork window and drop it on the floor, which is a shell
      # quirk, not the teardown behavior under test.
      handle = spawn_process("sleep", outlives_example.to_s)

      expect(handle.interrupt(grace: 5).termsig).to eq(Signal.list["INT"])
    end

    context "when the child ignores INT" do
      it "force kills it once the grace window closes" do
        handle = spawn_process("sh", "-c", 'trap "" INT; while :; do sleep 1; done')
        pid = handle.pid
        handle.interrupt(grace: 0.5)

        expect(ProcessProbe.new(pid)).not_to be_alive
      end
    end
  end
end
