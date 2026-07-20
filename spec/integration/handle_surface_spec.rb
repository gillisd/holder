RSpec.describe "the surface a handle exposes to its caller" do
  describe "#stdout" do
    # The point of running without a block: the handle outlives the call, so the
    # caller still has a readable stdout to pull the child's output from.
    it "survives the no-block form as a pipe the caller can read" do
      handle = spawn_process("sh", "-c", "echo hello")

      expect(handle.stdout.gets&.chomp).to eq("hello")
    end

    it "is nil when out: was redirected, since the caller already holds that IO" do
      handle = spawn_process("sh", "-c", "echo hi; sleep #{outlives_example}", out: open_tmp("w"))

      expect(handle.stdout).to be_nil
    end
  end

  describe "#stderr" do
    it "is still a pipe when only out: was redirected" do
      handle = spawn_process("sh", "-c", "echo hi; sleep #{outlives_example}", out: open_tmp("w"))

      expect(handle.stderr).not_to be_nil
    end
  end

  describe "#pid" do
    it "is the child's process id as an Integer" do
      handle = spawn_process("sh", "-c", "sleep #{outlives_example}")

      expect(handle.pid).to be_a(Integer)
    end
  end

  describe "its internal plumbing" do
    it "keeps the wait thread, pumps, owned pipes and mutex unreadable" do
      # The encapsulation guard from the Data.define -> plain class rewrite:
      # Data exposed every field as a public reader, so these must stay ivars.
      handle = spawn_process("sh", "-c", "sleep #{outlives_example}")

      %i[pump_threads owned_ios wait_thread mutex].each do |internal|
        expect(handle).not_to respond_to(internal)
      end
    end
  end
end
