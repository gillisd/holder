# Generous budget because the fixture is built, not just spawned: the helper
# shells out to cc and sudo to install a setuid binary before the example can
# start. What terminate itself may take is bounded explicitly below.
RSpec.describe "terminating a process group that is alive but cannot be signalled", timeout: 60 do
  let(:unsignalable_command) { UnsignalableCommand.path }
  let(:leaked_pgid) { [] }

  before do
    skip "EPERM from a group signal means gone here, not unsignalable" if Holder::Handle::EPERM_MEANS_GONE
    skip "host cannot host a setuid-root helper (needs a non-root uid, cc, passwordless sudo)" unless
      unsignalable_command
  end

  # The setuid-root binary is installed once for the whole group -- UnsignalableCommand.path
  # memoises the build -- so removing it is the group's business, not any one example's.
  # rubocop:disable RSpec/BeforeAfterAll
  after(:all) { UnsignalableCommand.remove }
  # rubocop:enable RSpec/BeforeAfterAll

  after { system("sudo", "-n", "kill", "-KILL", "-#{leaked_pgid.first}", err: File::NULL) if leaked_pgid.any? }

  it "surfaces the permission error instead of hanging or reporting a clean teardown" do
    handle = a_group_whose_leader_has_dropped_to_nobody

    expect { Timeout.timeout(3) { handle.terminate(grace: 0.5) } }.to raise_error(Errno::EPERM)
  end

  # The pgid is recorded before terminate runs, not after: terminate is expected to
  # fail, so nothing else will ever tell the after hook which group to reap as root.
  def a_group_whose_leader_has_dropped_to_nobody
    handle = spawn_process(unsignalable_command)
    leaked_pgid << Process.getpgid(handle.pid)
    sleep 0.4

    handle
  end
end
