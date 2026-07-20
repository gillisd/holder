RSpec.describe "tearing one child down from several threads at once" do
  let(:idle_child) { spawn_process("sh", "-c", "sleep #{outlives_example}") }

  def a_thread_already_blocked_in_wait(handle)
    Thread.new { handle.wait }.tap { |waiter| Thread.pass until waiter.status == "sleep" }
  end

  context "when terminate is called from a thread other than the one that spawned the child" do
    it "tears the child down without raising" do
      # Bound to a local first, so the child is unambiguously spawned here and
      # torn down over there. Referencing the lazy let straight from inside the
      # block would fork it on the terminating thread, and the example would no
      # longer be about crossing threads at all.
      spawned_on_this_thread = idle_child

      expect(error_raised_in_thread { spawned_on_this_thread.terminate(grace: 0.5) }).to be_nil
    end
  end

  context "when another thread is already blocked in #wait" do
    let!(:waiter) { a_thread_already_blocked_in_wait(idle_child) }

    it "is not held up behind the blocked waiter" do
      duration = elapsed { idle_child.terminate(grace: 0.5) }
      waiter.join

      expect(duration).to be < 2.0
    end
  end

  context "when a concurrent terminate is already sitting out a longer grace" do
    # The child speaks only after ignoring TERM, so the first terminate cannot
    # race the trap and is guaranteed to sit out its grace window.
    let!(:child_that_ignores_term) do
      spawn_process("sh", "-c", 'trap "" TERM; echo ready; while :; do sleep 1; done')
        .tap { |handle| handle.stdout.gets }
    end

    def a_terminate_already_sitting_out_a_two_second_grace(handle)
      timing = Thread.new { elapsed { handle.terminate(grace: 2) } }
      sleep 0.3
      timing
    end

    # Both bounds are facets of one staged race on a single shared clock:
    # re-spawning the trap-ignoring child to assert them separately would sit
    # out the patient grace twice for no extra coverage.
    it "tightens the shared escalation clock so the shorter grace ends both", :aggregate_failures do
      patient = a_terminate_already_sitting_out_a_two_second_grace(child_that_ignores_term)
      impatient = elapsed { child_that_ignores_term.terminate(grace: 0.2) }

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
