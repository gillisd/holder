require "test_helper"
require "stringio"

def fd_count = Dir.children("/proc/#{Process.pid}/fd").size

def running?(pid)
  return false if pid.to_i <= 0
  st = (File.read("/proc/#{pid}/status") rescue nil)
  return false unless st
  st[/State:\s*(\w)/, 1] != "Z"
end

# the group signal kills grandchildren asynchronously (they reparent to init),
# so liveness is eventually-false, not instantly-false. poll for it.
def dead_within?(pid, timeout = 3.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  sleep 0.02 while running?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  !running?(pid)
end

class HolderTest < Minitest::Test
  def setup
    @procs = []
    @tmp = []
  end

  def teardown
    @procs.each { |h| h.terminate(grace: 0.2) rescue nil }
    @tmp.each { |p| File.unlink(p) rescue nil }
  end

  def spawn(*cmd, **kw)
    h = Pb3::Process.new(*cmd).run(**kw); @procs << h; h
  end

  def tmpfile
    p = "/tmp/pb3_#{$$}_#{rand(1_000_000)}.txt"; @tmp << p; p
  end

  def input_io(content)
    p = tmpfile; File.write(p, content); File.open(p, "r")
  end

  def test_that_it_has_a_version_number
    refute_nil Holder::VERSION
  end

  # ---- correctness ---------------------------------------------------------

  def test_works_pipes_no_block
    h = spawn("sh", "-c", "echo hello")
    assert_equal "hello", h.stdout.gets&.chomp
    h.wait
  end

  def test_stdin_from_io_completes_no_hang # in: pump closes stdin -> filter sees EOF, exits
    path = tmpfile
    f = File.open(path, "w")
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Pb3::Process.new("sort").run(in: input_io("b\na\nc\n"), out: f).wait
    f.close
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 3, "must not hang"
    assert_equal "a\nb\nc", File.read(path).chomp
  end

  def test_in_only_combo # was a missing matrix branch (-> popen3)
    out = Pb3::Process.new("cat").run(in: input_io("solo\n")) { |io| io.stdout.read }
    assert_equal "solo", out.chomp
  end

  def test_in_plus_err_combo # the other missing branch (-> popen2, err direct)
    path = tmpfile
    f = File.open(path, "w")
    Pb3::Process.new("sh", "-c", "cat 1>&2").run(in: input_io("toerr\n"), err: f).wait
    f.close
    assert_equal "toerr", File.read(path).chomp
  end

  def test_works_block_form_auto_teardown
    pid = nil
    Pb3::Process.new("sh", "-c", "sleep 30").run { |io| pid = io.pid }
    assert dead_within?(pid), "block form should tear the process down on exit"
  end

  def test_works_direct_out_redirect_via_pump # popen3 pipes stdout; we pump it to the file
    path = tmpfile
    f = File.open(path, "w")
    Pb3::Process.new("sh", "-c", "echo to_file").run(out: f).wait # run to completion
    f.close
    assert_equal "to_file", File.read(path).chomp
  end

  def test_works_direct_err_redirect # popen2 honors err: directly (no pipe, no pump)
    path = tmpfile
    f = File.open(path, "w")
    Pb3::Process.new("sh", "-c", "echo oops 1>&2").run(err: f).wait
    f.close
    assert_equal "oops", File.read(path).chomp
  end

  def test_block_form_tears_down_no_block_form_does_not
    # block form: process is gone once the block returns
    bpid = nil
    Pb3::Process.new("sh", "-c", "sleep 30").run { |io| bpid = io.pid }
    assert dead_within?(bpid), "block form should tear down on block exit"

    # no-block form: process keeps running until YOU tear it down
    h = spawn("sh", "-c", "sleep 30")
    sleep 0.1
    assert running?(h.pid), "no-block form must NOT auto-tear-down; caller owns it"
    h.terminate(grace: 0.5)
    refute running?(h.pid)
  end

  # ---- the old flaws, now fixed (green = bug gone) -------------------------

  def test_fixed_no_esrch_when_already_exited # flaw #2
    h = spawn("true")
    sleep 0.02 while running?(h.pid)
    status = h.terminate # must NOT raise Errno::ESRCH
    assert_kind_of ::Process::Status, status
  end

  def test_fixed_sigkill_escalation # flaw #3a/#3b: ignores TERM -> still dies, fast
    h = spawn("sh", "-c", 'trap "" TERM; while :; do sleep 1; done')
    pid = h.pid
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    h.terminate(grace: 0.5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    refute running?(pid), "TERM-ignoring process should be SIGKILLed"
    assert_operator elapsed, :<, 3, "should escalate after grace, not hang"
  end

  def test_fixed_cross_thread_teardown # terminate from another thread is safe
    h = spawn("sh", "-c", "sleep 30")
    pid = h.pid
    err = nil
    Thread.new {
      begin
        h.terminate(grace: 0.5)
      rescue => e
        err = e
      end
    }.join
    assert_nil err, "cross-thread terminate must not raise"
    refute running?(pid)
  end

  def test_fixed_backgrounded_grandchild_reaped # group teardown reaches the shell-backgrounded grandchild
    h = spawn("sh", "-c", "sleep 31 & echo $!; sleep 31")
    bg_pid = h.stdout.gets.to_i
    assert running?(bg_pid), "sanity: backgrounded grandchild should be alive"
    h.terminate(grace: 0.5)
    assert dead_within?(bg_pid), "group teardown should kill the backgrounded grandchild"
  end

  # leader exits immediately, orphaning a grandchild that still holds the dead
  # leader's pgid -- terminate must still signal the group, not skip it
  def test_terminate_signals_group_when_leader_already_exited
    h = Pb3::Process.new("sh", "-c", "sleep 31 & echo $!").run # sh backgrounds, then returns
    gc = h.stdout.gets.to_i
    sleep 0.25 # let the leader exit
    @procs << h
    h.terminate(grace: 0.5)
    assert dead_within?(gc), "terminate must signal the group even after the leader has exited"
  ensure
    (Process.kill("KILL", gc) rescue nil) if gc
  end

  def test_fixed_double_terminate_idempotent
    h = spawn("sh", "-c", "sleep 30")
    a = h.terminate(grace: 0.5)
    b = h.terminate(grace: 0.5)
    assert_same a, b, "second terminate returns the same cached status, no raise"
    assert [h.stdin, h.stdout, h.stderr].all?(&:closed?), "pipes should be closed"
  end

  def test_handle_hygiene_hides_internals_and_redirected_streams
    f = File.open(tmpfile, "w")
    h = spawn("sh", "-c", "echo hi; sleep 5", out: f) # out redirected, err/in not
    assert_nil h.stdout, "a redirected stream must not expose its internal pipe"
    refute_nil h.stderr, "an un-redirected stream stays a usable pipe"
    assert_kind_of Integer, h.pid
    %i[pump_threads owned_ios wait_thread mutex].each do |internal|
      refute h.respond_to?(internal), "#{internal} is plumbing and must stay internal"
    end
    h.terminate(grace: 0.5)
  ensure
    f&.close
  end

  def test_fixed_interrupt_also_escalates # flaw #4: INT-ignoring process no longer survives teardown
    h = spawn("sh", "-c", 'trap "" INT; while :; do sleep 1; done')
    pid = h.pid
    h.interrupt(grace: 0.5)
    refute running?(pid), "INT-ignoring process should be SIGKILLed by interrupt's escalation"
  end

  # ---- production: resource accounting & error paths -----------------------

  def test_no_fd_or_thread_leak_over_many_cycles
    GC.start; sleep 0.1
    fds0, thr0 = fd_count, Thread.list.size
    150.times { Pb3::Process.new("sh", "-c", "echo hi").run { |io| io.stdout.read } }
    150.times do
      f = File.open(tmpfile, "w")
      Pb3::Process.new("sh", "-c", "echo hi").run(out: f) { |io| io.wait }
      f.close
    end
    150.times { Pb3::Process.new("cat").run(in: input_io("x\n")) { |io| io.stdout.read } }
    GC.start; sleep 0.4
    assert_operator fd_count - fds0, :<=, 2, "fds must not grow across spawn/teardown cycles"
    assert_operator Thread.list.size - thr0, :<=, 2, "threads must not grow across cycles"
  end

  def test_block_form_cleans_up_when_block_raises
    pid = nil
    assert_raises(RuntimeError) do
      Pb3::Process.new("sh", "-c", "sleep 30").run { |io| pid = io.pid; raise "boom" }
    end
    assert dead_within?(pid), "ensure must tear the child down even when the block raises"
  end

  def test_pump_error_is_captured_not_raised # a redirect failing mid-copy
    src = StringIO.new("data")
    bad = Object.new

    def bad.write(*) = raise("disk full") # stand-in for ENOSPC/EIO on write

    thread = Pb3::Process.allocate.send(:pump, src, bad)
    assert_kind_of RuntimeError, thread.value, "pump must capture the error as its value, not raise"
  end

  def test_pump_error_does_not_block_pipe_close
    r, w = IO.pipe
    _, _, _, wait = Open3.popen3("true") # a real, short-lived wait_thread
    failed = Thread.new { RuntimeError.new("disk full") } # a pump that finished with an error
    h = Pb3::Process::StdIo.new(
      stdin: nil, stdout: nil, stderr: nil,
      wait_thread: wait, pump_threads: [failed], owned_ios: [r, w]
    )
    h.terminate(grace: 0.5)
    assert [r, w].all?(&:closed?), "owned pipes must close even when a pump errored"
    assert_kind_of RuntimeError, h.pump_error, "the pump error is surfaced on the handle"
  end

  # dropping a no-block handle without terminate/wait leaks the process -- this
  # pins that contract so it can't silently change
  def test_dropped_no_block_handle_leaks_until_terminated
    pid = Pb3::Process.new("sh", "-c", "sleep 30").run.pid # handle goes out of scope
    GC.start; sleep 0.2
    assert running?(pid), "no-block handle isn't auto-reaped; caller must tear it down"
  ensure
    (Process.kill("-KILL", pid) rescue nil) if pid
  end

  # ---- regression: reviewer findings ---------------------------------------

  def test_matcher_lives_under_pb3_not_core_io # finding #1
    refute_includes ::IO.constants, :InputStream, "must not patch core ::IO"
    assert_includes Pb3.constants, :Stream, "the matcher belongs under Pb3"
  end

  def test_matcher_rejects_non_io_arguments # finding #2
    [0, 1, 2, 64, "/dev/null", "log.txt", :stdin, StringIO.new("x")].each do |bad|
      refute(Pb3::Stream === bad, "#{bad.inspect} is not an IO and must be rejected")
    end
    f = File.open(tmpfile, "w")
    [$stdin, $stdout, f].each do |good|
      assert(Pb3::Stream === good, "#{good.class} is a real IO and must be accepted")
    end
    f.close
  end

  def test_run_rejects_non_io_redirect_up_front # finding #3 (no silent detonation)
    assert_raises(ArgumentError) { Pb3::Process.new("cat").run(in: 0) }
    assert_raises(ArgumentError) { Pb3::Process.new("cat").run(out: "log.txt") }
    assert_raises(ArgumentError) { Pb3::Process.new("cat").run(err: StringIO.new) }
  end

  def test_kwargs_forwarded_to_spawn # finding #4
    dir = "/tmp/pb3_chdir_#{$$}_#{rand(1_000_000)}"
    Dir.mkdir(dir)
    out = tmpfile; f = File.open(out, "w")
    Pb3::Process.new("sh", "-c", "pwd").run(out: f, chdir: dir).wait
    f.close
    assert_equal dir, File.read(out).strip, "chdir kwarg must reach spawn"
  ensure
    Dir.rmdir(dir) rescue nil
  end

  def test_kwargs_cannot_override_pgroup # our pgroup:true must win
    # child backgrounds a grandchild; pass a bogus pgroup and confirm group
    # teardown still reaches the grandchild (i.e. the child got its own group)
    h = Pb3::Process.new("sh", "-c", "sleep 31 & echo $!; sleep 31").run(pgroup: false)
    @procs << h
    gc = h.stdout.gets.to_i
    h.terminate(grace: 0.5)
    assert dead_within?(gc), "pgroup:true must win over a kwargs pgroup so teardown reaches the group"
  end

  def test_wait_does_not_starve_terminate # finding #5
    h = spawn("sh", "-c", "sleep 30")
    waiter = Thread.new { h.wait }
    sleep 0.2
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    h.terminate(grace: 0.5)
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    waiter.join
    assert_operator dt, :<, 2.0, "terminate must not block behind a concurrent wait (took #{dt.round(2)}s)"
  end

  def test_terminate_bounded_with_never_eof_input # found while testing #2/#3
    r, w = IO.pipe; w.write("partial, no EOF\n") # writer kept open -> r never EOFs
    h = Pb3::Process.new("cat").run(in: r)
    @procs << h
    sleep 0.2
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    h.terminate(grace: 0.5)
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_operator dt, :<, Pb3::Process::PUMP_GRACE + 2,
                    "an in: pump stuck on a non-EOF source must not wedge terminate (took #{dt.round(2)}s)"
  ensure
    w.close rescue nil
  end
end