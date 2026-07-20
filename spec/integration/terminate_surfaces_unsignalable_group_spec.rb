RSpec.describe Holder::Handle do
  # Generous budget because the fixture is built, not just spawned: the helper
  # shells out to cc and sudo to install a setuid binary before the example can
  # start. What terminate itself may take is bounded explicitly below.
  describe "#terminate when the process group is alive but cannot be signalled", timeout: 60 do
    after(:all) { UnsignalableCommand.remove }

    it "surfaces the permission error instead of hanging or reporting a clean teardown" do
      skip "EPERM from a group signal means gone here, not unsignalable" if Holder::Handle::EPERM_MEANS_GONE

      command = UnsignalableCommand.path
      skip "host cannot host a setuid-root helper (needs a non-root uid, cc, passwordless sudo)" unless command

      handle = spawn_process(command)
      @leaked_pgid = Process.getpgid(handle.pid)
      sleep 0.4

      expect { Timeout.timeout(3) { handle.terminate(grace: 0.5) } }.to raise_error(Errno::EPERM)
    end

    after { system("sudo", "-n", "kill", "-KILL", "-#{@leaked_pgid}", err: File::NULL) if @leaked_pgid }
  end
end
