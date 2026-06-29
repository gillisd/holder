module Holder
  # A live process handle.
  #
  # A regular class, not a Data: a handle is stateful (it gets torn down) and
  # has internals to hide. Data.define exposes every field as a public reader,
  # which is the leak we're closing -- so the wait_thread, pump threads, owned
  # pipes, and mutex live in ivars with no readers.
  #
  # Public surface: stdin/stdout/stderr (only the streams you did NOT redirect;
  # a redirected stream is talked to via your own IO, so its accessor is nil),
  # pid, and terminate/interrupt/wait.
  #
  # Teardown is plain method calls guarded by a mutex, so it's idempotent,
  # thread-safe, and callable from any thread. terminate and interrupt are the
  # same robust teardown differing only in the first signal: send it, wait
  # GRACE for the group to die, then guarantee death with SIGKILL, reap the
  # child, join the pumps, and close the pipes we own.
  class Handle
    # seconds to wait after the first signal before escalating to SIGKILL
    GRACE = 5

    # seconds to wait for a pump to drain after the process exits
    # before interrupting it (see reap_pumps)
    PUMP_GRACE = 1

    # interval between process-group liveness polls while awaiting the grace window
    POLL = 0.02

    attr_reader :stdin, :stdout, :stderr, :pid, :pump_error

    def initialize(stdin:, stdout:, stderr:, wait_thread:, pump_threads:, owned_ios:) # rubocop:disable Metrics/ParameterLists
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @wait_thread = wait_thread
      @pump_threads = pump_threads
      @owned_ios = owned_ios
      @pid = wait_thread.pid
      @pump_error = nil
      @mutex = Mutex.new
    end

    def terminate(grace: GRACE) = teardown("TERM", grace)

    def interrupt(grace: GRACE) = teardown("INT", grace)

    # Wait for the process to exit on its own, then reap its group and finalize.
    def wait
      # Block on the waiter OUTSIDE the mutex: Thread#value is itself
      # thread-safe, and holding the mutex across the block would wedge a
      # concurrent terminate -- it could not acquire the mutex to signal until
      # the process exited on its own. finalize runs under the mutex and is
      # idempotent, so a terminate signal that finalizes first is harmless.
      status = @wait_thread.value
      @mutex.synchronize do
        # The leader exited on its own, but a grandchild it backgrounded can
        # outlive it in the same group -- so reap the group before finalizing, or
        # wait would leave it orphaned (no child left behind). wait is passive
        # (it sent no first signal), so leftovers are killed outright rather than
        # given grace. The KILL is guarded on group membership: only fire while
        # the group still has members, so its pgid is reserved and the signal
        # can't hit a recycled pid. Killing first also lets an out:/in: pump
        # drain instead of stalling on a pipe the grandchild held open.
        signal_group("KILL") if group_alive?
        finalize
      end
      status
    end

    private

    def teardown(signal, grace)
      @mutex.synchronize do
        # Always signal the group, even if the leader has already exited: an
        # orphaned grandchild keeps the leader's pgid, so the group outlives
        # the leader and still needs the signal. signal_group rescues ESRCH if
        # the group is genuinely empty.
        signal_group(signal)
        # Grace is measured against the whole GROUP, not just the leader: poll
        # membership so a grandchild the leader backgrounded gets the same grace
        # to shut down cleanly. Then KILL whatever is left -- but only while the
        # group still has members, so its pgid is reserved and the signal can't
        # land on a recycled pid.
        await_group_exit(grace)
        signal_group("KILL") if group_alive?
        @wait_thread.join
        finalize
        @wait_thread.value
      end
    end

    def signal_group(signal)
      Process.kill("-#{signal}", @pid)
    rescue Errno::ESRCH
      # the group is empty (leader already reaped and no surviving members);
      # nothing to signal
    end

    # Block until the process group is empty or +grace+ seconds elapse.
    def await_group_exit(grace)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
      sleep POLL while group_alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    end

    # True while any process remains in the group. Signal 0 probes the group
    # without delivering anything; ESRCH means it is empty.
    def group_alive?
      Process.kill(0, -@pid)
      true
    rescue Errno::ESRCH
      false
    end

    def finalize
      @pump_error ||= reap_pumps
      @owned_ios.each { |io| io.close unless io.closed? }
    end

    # Join the pumps, but never let one wedge teardown. Once the process has
    # exited, a healthy pump finishes draining in milliseconds, so it joins
    # within PUMP_GRACE and is never touched. A pump still blocked after that
    # is stuck on a misbehaving user IO -- an in: source that never reaches EOF
    # ($stdin, an open socket), or an out: sink that never drains -- and its
    # remaining work is moot now that the child is gone. Thread#kill unblocks
    # copy_stream's read/write and runs the pump's ensure (which closes its
    # pipe); a killed pump's #value is nil, so it's ignored here while a genuine
    # captured error is still surfaced as pump_error.
    def reap_pumps
      @pump_threads.filter_map do |t|
        unless t.join(PUMP_GRACE)
          (t.kill
           t.join)
        end
        t.value
      end.first
    end
  end
end
