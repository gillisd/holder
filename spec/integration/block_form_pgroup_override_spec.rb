RSpec.describe Holder::Tenant do
  describe "#run block form given a user-supplied pgroup: override" do
    it "keeps the child leading its own process group" do
      # The group is the unit of teardown, so pgroup: is never overridable: the
      # block form forces pgroup: true over the user kwargs, exactly as the
      # no-block form does (test_pgroup_true_cannot_be_overridden_by_kwargs).
      child_pid = nil
      child_pgid = nil
      Holder::Tenant.new("sh", "-c", "sleep 0.2", pgroup: false).run do |handle|
        child_pid = handle.pid
        child_pgid = Process.getpgid(handle.pid)
      end

      expect(child_pgid).to eq(child_pid)
    end
  end
end
