RSpec.describe Holder::Tenant do
  describe "#run block form" do
    it "tears down the child once the block returns" do
      child_pid = nil
      Holder::Tenant.new("sh", "-c", "sleep #{outlives_example}").run { |handle| child_pid = handle.pid }
      cleanup.pid(child_pid, group: true)

      expect(ProcessProbe.new(child_pid)).to be_dead_within(2)
    end

    context "when the block raises" do
      it "tears the child down and lets the error propagate" do
        child_pid = nil

        expect do
          Holder::Tenant.new("sh", "-c", "sleep #{outlives_example}").run do |handle|
            child_pid = handle.pid
            raise "boom"
          end
        end.to raise_error(RuntimeError)
        cleanup.pid(child_pid, group: true)

        expect(ProcessProbe.new(child_pid)).to be_dead_within(2)
      end
    end
  end

  describe "#run without a block" do
    it "leaves a dropped handle's child running" do
      # Teardown is the caller's in the no-block form, so the handle must not
      # carry a finalizer that reaps the child behind their back. The handle is
      # never bound to a local -- only its pid is kept -- so it is unreachable
      # by the time GC runs, and the pause gives any finalizer room to fire.
      child_pid = cleanup.pid(Holder::Tenant.new("sh", "-c", "sleep #{outlives_example}").run.pid, group: true)
      GC.start
      sleep 0.2

      expect(ProcessProbe.new(child_pid)).to be_alive
    end
  end
end
