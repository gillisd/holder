RSpec.describe ProcessProbe do
  # Children are spawned bare and left unwaited rather than going through the
  # cleanup registry: a process is only a zombie while nobody has reaped it, and
  # that is the state the zombie contract needs staged. The registry kills but
  # never waits -- right for the grandchildren other specs probe, wrong here,
  # where every child is our own and would linger as a zombie of the spec run.
  let(:spawned_children) { [] }

  after { kill_and_reap(spawned_children.shift) until spawned_children.empty? }

  def spawn_child(*command)
    Process.spawn(*command).tap { |pid| spawned_children << pid }
  end

  # Best-effort, per child: one that already exited or was already reaped raises
  # ESRCH/ECHILD, and swallowing that is what keeps the rest of the registered
  # children from being stranded by an early failure.
  def kill_and_reap(pid)
    spawned_children.delete(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # `true` exits at once, but nothing waits on it, so the kernel keeps the entry
  # around as a zombie -- the one state where the pid still resolves even though
  # the process is gone for good.
  # Polled a fixed number of times rather than against a wall clock: on the
  # macOS/BSD fallback every poll forks a ps, so a wall-clock deadline would
  # buy far fewer attempts there than on Linux procfs, exactly where the
  # process is slowest to be reaped.
  def zombie_probe_for(pid)
    probe = described_class.new(pid)
    100.times do
      break if probe.zombie?

      sleep 0.01
    end
    probe
  end

  describe "#alive?" do
    it "is true while the process is running" do
      expect(described_class.new(spawn_child("sleep", outlives_example.to_s))).to be_alive
    end

    # 0 and -1 are not processes: to kill(2) they mean "my own group" and "every
    # process I may signal", so a probe must never report either as alive.
    it "is false for pid 0, which kill(2) reads as the caller's own group" do
      expect(described_class.new(0)).not_to be_alive
    end

    it "is false for pid -1, which kill(2) reads as every signalable process" do
      expect(described_class.new(-1)).not_to be_alive
    end

    it "is false once the process has been reaped" do
      pid = spawn_child("sleep", outlives_example.to_s)
      kill_and_reap(pid)

      expect(described_class.new(pid)).not_to be_alive
    end

    # Aggregated rather than split: reaching the zombie state is what the polling
    # buys, so "we really did stage a zombie" and "a zombie is not alive" are two
    # facets of one staging that a split would have to pay for twice -- and the
    # second example would then trust an unasserted precondition.
    it "is false for a zombie whose parent has not reaped it yet", :aggregate_failures do
      probe = zombie_probe_for(spawn_child("true"))

      expect(probe).to be_zombie
      expect(probe).not_to be_alive
    end
  end

  describe "#dead_within?" do
    it "is true when the process exits inside the window" do
      expect(described_class.new(spawn_child("sleep", "0.2"))).to be_dead_within(2)
    end

    it "is false when the process outlives the window" do
      expect(described_class.new(spawn_child("sleep", outlives_example.to_s))).not_to be_dead_within(0.2)
    end
  end
end
