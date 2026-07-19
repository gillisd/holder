RSpec.describe Holder::Handle do
  describe "#terminate when the process group is alive but cannot be signalled" do
    it "surfaces the permission error instead of hanging or reporting a clean teardown" do
      handle = spawn_process("sleep", "5")
      @unsignalable_pid = handle.pid
      allow(Process).to receive(:kill).and_raise(Errno::EPERM)

      expect { Timeout.timeout(2) { handle.terminate(grace: 0.5) } }
        .to raise_error(Errno::EPERM)
    end

    after { system("kill", "-KILL", "-#{@unsignalable_pid}", err: File::NULL) if @unsignalable_pid }
  end
end
