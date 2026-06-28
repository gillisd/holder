##
# Polls <tt>/proc/<pid>/status</tt> to observe whether a process is alive,
# treating a zombie (state +Z+) as dead. Used to assert teardown actually
# reaped a child or its group.
class ProcessProbe
  POLL = 0.02

  def initialize(pid)
    @pid = pid.to_i
  end

  def alive?
    return false unless @pid.positive?

    state = read_state
    !state.nil? && state != "Z"
  end

  def dead_within?(timeout)
    deadline = Clock.monotonic + timeout
    sleep POLL while alive? && Clock.monotonic < deadline
    !alive?
  end

  private

  def read_state
    File.read("/proc/#{@pid}/status")[/State:\s*(\w)/, 1]
  rescue SystemCallError
    nil
  end
end
