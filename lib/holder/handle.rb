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
  # child, join the pumps, and close the pipes we own. Concurrent teardowns
  # share one escalation clock -- the earliest deadline any caller asked for
  # wins -- so a terminate(grace: 0) is never wedged behind another caller's
  # longer grace. wait is the passive counterpart: no first signal, leftovers
  # killed outright, and a redirected out: sink drained to the last byte
  # rather than deadline-killed, however slow that sink is.
  class Handle
    # seconds to wait after the first signal before escalating to SIGKILL
    GRACE = 5

    # seconds to wait for a pump to drain after the process exits
    # before interrupting it (see reap_pumps)
    PUMP_GRACE = 1

    # interval between process-group liveness polls while awaiting the grace window
    POLL = 0.02

    # Whether an EPERM from a group signal means the group is gone. macOS/BSD
    # report a zombie-only group (its last survivor a defunct process) as EPERM,
    # so there it means gone. Linux never reports EPERM for a group we own -- there
    # EPERM means the group is alive but unsignalable (e.g. a child that dropped
    # privilege), which must surface rather than be mistaken for an empty group.
    EPERM_MEANS_GONE = !RUBY_PLATFORM.include?("linux")

    attr_reader :stdin, :stdout, :stderr, :pid, :pump_error

    def initialize(stdin:, stdout:, stderr:, wait_thread:, pump_threads:, owned_ios:, drain_pump: nil) # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @wait_thread = wait_thread
      @pump_threads = pump_threads
      @drain_pump = drain_pump
      @owned_ios = owned_ios
      @pid = wait_thread.pid
      @pump_error = nil
      @mutex = Mutex.new
      @escalation_tick = ConditionVariable.new
      @kill_deadline = nil
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
      @mutex.synchronize { kill_group_leftovers }
      # The child exited on its own, so bytes still buffered toward an out:
      # sink are real output the caller asked for -- join the drain pump
      # unbounded and deliver every one of them. Outside the mutex, so a
      # concurrent terminate stays free to cut a wedged sink short: its pump
      # kill makes this join return.
      @drain_pump&.join
      @mutex.synchronize { finalize }
      status
    end

    private

    def teardown(signal, grace)
      @mutex.synchronize do
        # Always signal the group, even if the leader has already exited: an
        # orphaned grandchild keeps the leader's pgid, so the group outlives
        # the leader and still needs the signal. signal_group rescues the
        # empty-group case.
        signal_group(signal)
        # Grace is measured against the whole GROUP, not just the leader: poll
        # membership so a grandchild the leader backgrounded gets the same grace
        # to shut down cleanly, then KILL whatever is left. The membership guard
        # narrows -- but cannot close -- the window in which a recycled pgid
        # could be signalled: kill(0) has no way to prove the group is still
        # ours, an inherent hazard of addressing processes by id.
        await_group_exit(grace)
        signal_group("KILL") if group_alive?
        @wait_thread.join
        finalize
        @kill_deadline = nil
        @wait_thread.value
      end
    end

    def signal_group(signal)
      begin
        Process.kill("-#{signal}", @pid)
      rescue Errno::ESRCH
        # An empty group -- the leader is reaped and no members survive; nothing
        # left to signal.
      rescue Errno::EPERM
        # macOS/BSD: a zombie-only group, also nothing left to signal. Linux: the
        # group is alive but unsignalable -- surface it rather than silently
        # treating the group as reaped.
        raise unless EPERM_MEANS_GONE
      end
    end

    # Block until the process group is empty or the shared kill deadline
    # passes. Concurrent teardowns tighten one clock -- the earliest requested
    # deadline wins -- and each tick releases the mutex, so a second caller is
    # never wedged behind an in-flight grace window: it gets in, tightens the
    # deadline, and every caller escalates together.
    def await_group_exit(grace)
      requested = monotonic + grace
      @kill_deadline = [@kill_deadline || requested, requested].min
      while group_alive?
        deadline = @kill_deadline
        break if deadline.nil? || monotonic >= deadline

        @escalation_tick.wait(@mutex, POLL)
      end
    end

    # wait sent no first signal, so group leftovers get no grace: a grandchild
    # that outlived the leader is killed outright (no child left behind), which
    # also releases any pipe end it held open so wait's drain can finish.
    # Unless a terminate/interrupt is mid-grace -- then honor its window rather
    # than cutting it short, and fire its overdue KILL ourselves only if that
    # teardown never escalated (its thread may have died mid-flight).
    def kill_group_leftovers
      while group_alive?
        deadline = @kill_deadline
        break signal_group("KILL") if deadline.nil? || monotonic >= deadline

        @escalation_tick.wait(@mutex, POLL)
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # True while any signalable process remains in the group. Signal 0 probes the
    # group without delivering anything: the group is no longer alive only when the
    # probe raises a GROUP_GONE error (an empty group everywhere, plus a zombie-only
    # group on macOS/BSD). A Linux EPERM -- alive but unsignalable -- is not caught
    # here and surfaces to the caller rather than masquerading as a dead group.
    def group_alive?
      begin
        Process.kill(0, -@pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        # See EPERM_MEANS_GONE: gone on macOS/BSD, but on Linux the group is alive
        # and unsignalable, which must surface rather than read as a dead group.
        raise unless EPERM_MEANS_GONE

        false
      end
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
    # pipe); a killed pump's #value is nil, so it's ignored here. Of the
    # genuine captured errors, the drain pump's outranks the feed pump's: a
    # failed drain lost output the caller redirected, while a failed feed
    # merely starved a child that is already gone.
    def reap_pumps
      errors = @pump_threads.filter_map do |pump|
        unless pump.join(PUMP_GRACE)
          pump.kill
          pump.join
        end
        error = pump.value
        [pump, error] if error
      end.to_h
      errors[@drain_pump] || errors.values.first
    end
  end
end
