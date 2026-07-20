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
  # killed outright, and a redirected out: sink drained for a caller-tunable
  # drain_grace (defaulting well past a teardown's PUMP_GRACE) -- bounded so a
  # sink that never drains can't wedge wait, with a cut-short drain surfaced
  # as a StalledSinkError in pump_error rather than a silent truncation.
  class Handle
    # seconds to wait after the first signal before escalating to SIGKILL
    GRACE = 5

    # seconds to wait for a pump to drain after the process exits
    # before interrupting it (see reap_pumps)
    PUMP_GRACE = 1

    # interval between process-group liveness polls while awaiting the grace window
    POLL = 0.02

    # default for wait's drain_grace: seconds wait keeps delivering a redirected
    # out: sink's buffered output -- patient well past a teardown's PUMP_GRACE --
    # before giving up on a sink that never drains, so a wedged sink cannot block
    # wait forever
    WAIT_DRAIN_GRACE = 2

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
    # A redirected out: sink gets drain_grace seconds to finish draining (see
    # deliver_redirected_output).
    def wait(drain_grace: WAIT_DRAIN_GRACE)
      # Block on the waiter OUTSIDE the mutex: Thread#value is itself
      # thread-safe, and holding the mutex across the block would wedge a
      # concurrent terminate -- it could not acquire the mutex to signal until
      # the process exited on its own. finalize runs under the mutex and is
      # idempotent, so a terminate signal that finalizes first is harmless.
      status = @wait_thread.value
      begin
        @mutex.synchronize { kill_group_leftovers }
        deliver_redirected_output(drain_grace)
      ensure
        # finalize even if reaping the group raised (an unsignalable group surfaces
        # EPERM), so the owned pipes are always closed.
        @mutex.synchronize { finalize }
      end
      status
    end

    private

    # The child exited on its own, so bytes still buffered toward an out: sink are
    # real output the caller asked for -- join the drain pump so it delivers them,
    # patient well past a teardown's PUMP_GRACE by default, and a caller with a
    # slower sink can raise drain_grace further. But a sink that never drains (a
    # full pipe whose reader never reads) would wedge wait forever, so once the
    # grace passes kill the pump and record the discarded output as a
    # StalledSinkError in pump_error -- truncation surfaces, never passes as a
    # clean delivery. Runs outside the mutex, so a concurrent terminate can still
    # cut a wedged sink short even sooner.
    def deliver_redirected_output(drain_grace)
      return if @drain_pump.nil? || @drain_pump.join(drain_grace)

      @drain_pump.kill
      @drain_pump.join
      @mutex.synchronize { @pump_error ||= StalledSinkError.new(drain_grace) }
    end

    def teardown(signal, grace)
      @mutex.synchronize do
        begin
          escalate(signal, grace)
        ensure
          # Close our pipes and reap the pumps even when escalate raised -- a group
          # we cannot signal surfaces EPERM, and the handle's resources must still
          # be released rather than leaked.
          finalize
          @kill_deadline = nil
        end
        @wait_thread.value
      end
    end

    # Send the first signal, grant the whole GROUP grace to exit, then guarantee
    # death with SIGKILL and reap the leader.
    def escalate(signal, grace)
      # Always signal the group, even if the leader has already exited: an orphaned
      # grandchild keeps the leader's pgid, so the group outlives the leader and
      # still needs the signal. signal_group rescues the empty-group case.
      signal_group(signal)
      # Grace is measured against the whole GROUP, not just the leader: poll
      # membership so a grandchild the leader backgrounded gets the same grace to
      # shut down cleanly, then KILL whatever is left. The membership guard narrows
      # -- but cannot close -- the window in which a recycled pgid could be
      # signalled: probing liveness cannot prove the group is still ours, an
      # inherent hazard of addressing processes by id.
      await_group_exit(grace)
      signal_group("KILL") if group_alive?
      @wait_thread.join
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

    # True while the process group still has a member. getpriority with PRIO_PGRP
    # probes the group directly by its (positive) group id and sends no signal,
    # raising ESRCH once the group is empty. On Linux reading a group's priority
    # needs no permission, so a live-but-unsignalable group correctly reads as
    # alive and its EPERM surfaces where we actually signal it, in signal_group;
    # macOS/BSD instead report a zombie-only group as EPERM, which means gone here.
    def group_alive?
      begin
        Process.getpriority(Process::PRIO_PGRP, @pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
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
