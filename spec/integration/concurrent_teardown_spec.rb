RSpec.describe Holder::Handle do
  describe "#terminate" do
    context "when called from a thread other than the one that spawned the child" do
      it "tears the child down without raising" do
        handle = spawn_process("sh", "-c", "sleep #{outlives_example}")

        expect(error_raised_in_thread { handle.terminate(grace: 0.5) }).to be_nil
      end
    end

    context "when another thread is already blocked in #wait" do
      it "is not held up behind the blocked waiter" do
        handle = spawn_process("sh", "-c", "sleep #{outlives_example}")
        waiter = Thread.new { handle.wait }
        Thread.pass until waiter.status == "sleep"
        duration = elapsed { handle.terminate(grace: 0.5) }
        waiter.join

        expect(duration).to be < 2.0
      end
    end

    context "when a concurrent terminate is already sitting out a longer grace" do
      it "tightens the shared escalation clock so the shorter grace ends both", :aggregate_failures do
        # The child speaks only after ignoring TERM, so the first terminate cannot
        # race the trap and is guaranteed to sit out its grace window.
        handle = spawn_process("sh", "-c", 'trap "" TERM; echo ready; while :; do sleep 1; done')
        handle.stdout.gets
        patient = Thread.new { elapsed { handle.terminate(grace: 2) } }
        sleep 0.3
        impatient = elapsed { handle.terminate(grace: 0.2) }

        expect(impatient).to be < 1.0
        expect(patient.value).to be < 1.8
      end
    end

    context "when the redirected in: source never reaches EOF" do
      it "stays bounded by the pump grace rather than waiting out the source" do
        handle = spawn_process("cat", in: never_eof_source)
        sleep 0.2

        expect(elapsed { handle.terminate(grace: 0.5) }).to be < Holder::Handle::PUMP_GRACE + 2
      end
    end
  end
end
