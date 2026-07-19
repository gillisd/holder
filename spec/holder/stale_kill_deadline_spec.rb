RSpec.describe Holder::Handle do
  describe "#terminate interrupted mid-grace after it arms the escalation deadline" do
    it "clears @kill_deadline so a later teardown starts from a fresh clock" do
      handle = spawn_process("sh", "-c", 'trap "" TERM; echo ready; exec sleep 300')
      handle.stdout.gets
      terminating = Thread.new { handle.terminate(grace: 5) }
      terminating.report_on_exception = false
      sleep 0.3
      terminating.raise(Interrupt)
      Thread.pass while terminating.alive?

      expect(handle.instance_variable_get(:@kill_deadline)).to be_nil
    end
  end
end
