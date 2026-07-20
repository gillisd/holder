##
# Observes whether a process is alive, treating a zombie (state +Z+) as dead.
# Used to assert teardown actually reaped a child or its group.
#
# Reads the process state from <tt>/proc/<pid>/status</tt> where procfs exists
# (Linux) and falls back to <tt>ps</tt> elsewhere (macOS/BSD), so the same
# liveness and zombie semantics hold on every platform the suite runs on.
class ProcessProbe
  POLL = 0.02
  PROCFS = File.directory?("/proc/self") # Linux exposes procfs; macOS/BSD do not

  def initialize(pid)
    @pid = pid.to_i
  end

  def alive?
    return false unless @pid.positive?

    state = read_state
    !state.nil? && state != "Z"
  end

  def zombie?
    @pid.positive? && read_state == "Z"
  end

  def dead_within?(timeout)
    deadline = Clock.monotonic + timeout
    sleep POLL while alive? && Clock.monotonic < deadline
    !alive?
  end

  private

  # The process's state character (e.g. +R+, +S+, +Z+), or nil once the process
  # no longer exists.
  def read_state
    PROCFS ? read_state_via_procfs : read_state_via_ps
  end

  def read_state_via_procfs
    File.read("/proc/#{@pid}/status")[/State:\s*(\w)/, 1]
  rescue SystemCallError
    nil
  end

  # ps prints the STAT column (its first character is the state; a missing
  # process prints nothing) -- the array form runs ps directly, no shell.
  def read_state_via_ps
    IO.popen(["ps", "-o", "stat=", "-p", @pid.to_s], err: File::NULL, &:read).lstrip[0]
  end
end
