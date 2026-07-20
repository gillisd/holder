RSpec.describe "refusing a caller's pgroup: override" do
  # The group is the unit of teardown, so pgroup: is never overridable: the
  # child leads its own group no matter what the caller passes. Both forms
  # force pgroup: true over the user kwargs, so both are specified here.
  context "with the no-block form" do
    it "still tears down a grandchild the leader backgrounded" do
      idle_with_backgrounded_child = "sleep #{outlives_example} & echo $!; sleep #{outlives_example}"
      handle = spawn_process("sh", "-c", idle_with_backgrounded_child, pgroup: false)
      grandchild = live_pid_from(handle.stdout)
      handle.terminate(grace: 0.5)

      expect(ProcessProbe.new(grandchild)).to be_dead_within(2)
    end
  end

  context "with the block form" do
    let(:child_identity) { {} }

    before do
      Holder::Tenant.new("sh", "-c", "sleep 0.2", pgroup: false).run do |handle|
        child_identity.merge!(pid: handle.pid, pgid: Process.getpgid(handle.pid))
      end
    end

    # fetch, not [], so the example cannot pass by comparing two nils if the
    # staging above ever stops populating the hash.
    it "keeps the child leading its own process group" do
      expect(child_identity[:pgid]).to eq(child_identity.fetch(:pid))
    end
  end
end
