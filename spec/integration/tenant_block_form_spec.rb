RSpec.describe "which side of Tenant#run owns tearing the child down" do
  # The pid is all an example has left to probe: run tears the handle down before
  # it returns, so the pid is carried out of the block -- and onto the teardown
  # registry -- while the handle is still in scope.
  let(:staged_pid) { [] }

  # Idles far past the example, so a child still alive at the assertion is one
  # teardown failed to reap rather than one that had already exited on its own.
  def tenant_that_idles_past_the_example
    Holder::Tenant.new("sh", "-c", "sleep #{outlives_example}")
  end

  # Registered from inside the block so a scenario that unwinds through a raise
  # still leaves the child on the registry rather than stranding it.
  def stage_for_teardown(handle)
    staged_pid << cleanup.pid(handle.pid, group: true)
  end

  def child = ProcessProbe.new(staged_pid.first)

  describe "the block form" do
    def run_a_block_that_returns
      tenant_that_idles_past_the_example.run { |handle| stage_for_teardown(handle) }
    end

    def run_a_block_that_raises
      tenant_that_idles_past_the_example.run do |handle|
        stage_for_teardown(handle)
        raise "boom"
      end
    end

    # Hands the error back as a value rather than letting it escape, so the
    # teardown example asserts teardown alone and leaves propagation to the
    # example that names that contract.
    def unwind_the_block_with_a_raise
      run_a_block_that_raises
    rescue RuntimeError => e
      e
    end

    it "tears the child down once the block returns" do
      run_a_block_that_returns

      expect(child).to be_dead_within(2)
    end

    it "tears the child down even when the block raises" do
      unwind_the_block_with_a_raise

      expect(child).to be_dead_within(2)
    end

    it "lets the block's error propagate to the caller" do
      expect { run_a_block_that_raises }.to raise_error(RuntimeError)
    end
  end

  describe "the no-block form" do
    # The handle is never bound to a local -- only its pid is kept -- so it is
    # unreachable by the time GC runs, and the pause gives any finalizer room to
    # fire.
    def drop_the_handle_keeping_only_its_pid
      staged_pid << cleanup.pid(tenant_that_idles_past_the_example.run.pid, group: true)
      GC.start
      sleep 0.2
    end

    it "leaves a dropped handle's child running" do
      # Reaping must be deterministic -- an explicit terminate/wait, or the
      # process-exit backstop -- never a GC finalizer firing mid-run behind the
      # caller's back. So a collected handle leaves its child running; the child
      # goes down with the process, not with the garbage collector.
      drop_the_handle_keeping_only_its_pid

      expect(child).to be_alive
    end
  end
end
