RSpec.describe Holder::Handle do
  describe "#terminate when the process group is alive but cannot be signalled" do
    after(:all) { SetuidDropper.remove }

    it "surfaces the permission error instead of hanging or reporting a clean teardown" do
      dropper = SetuidDropper.command
      skip "host cannot host a setuid-root helper (needs a non-root uid, cc, passwordless sudo)" unless dropper

      handle = spawn_process(dropper)
      @leaked_pgid = Process.getpgid(handle.pid)
      sleep 0.4

      expect { Timeout.timeout(3) { handle.terminate(grace: 0.5) } }.to raise_error(Errno::EPERM)
    end

    after { system("sudo", "-n", "kill", "-KILL", "-#{@leaked_pgid}", err: File::NULL) if @leaked_pgid }
  end
end
