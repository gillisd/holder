RSpec.describe Holder::Tenant do
  describe "#run block form given a user-supplied pgroup: override" do
    it "leaves the child in the caller's process group" do
      # DESIRED: the block form should refuse a user pgroup: override and keep the
      # child leading its own process group, exactly as the no-block form already
      # does (test_pgroup_true_cannot_be_overridden_by_kwargs). The group is the
      # unit of teardown, so it must never be overridable -- child_pgid should
      # equal the child's own pid.
      # CURRENT (asserted here): the block form merges the user kwargs after the
      # forced pgroup: true, so pgroup: false wins and the child stays in the
      # caller's group -- breaking the "not overridable" invariant on this path.
      child_pgid = nil
      Holder::Tenant.new("sh", "-c", "sleep 0.2", pgroup: false).run do |io|
        child_pgid = Process.getpgid(io.pid)
      end

      expect(child_pgid).to eq(Process.getpgid(0))
    end
  end
end
