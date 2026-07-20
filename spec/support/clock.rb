##
# Monotonic clock used by the tests to measure elapsed time without being
# affected by wall-clock changes.
module Clock
  def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
