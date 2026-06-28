require "test_helper"
require "English"
require "open3"
require "stringio"
require "pathname"
require "fileutils"
require "timeout"

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def fd_count = Pathname.new("/proc/#{Process.pid}/fd").children.size

def running?(pid)
  return false if pid.to_i <= 0

  st = begin
    File.read("/proc/#{pid}/status")
  rescue StandardError
    nil
  end
  return false unless st

  st[/State:\s*(\w)/, 1] != "Z"
end

# the group signal kills grandchildren asynchronously (they reparent to init),
# so liveness is eventually-false, not instantly-false. poll for it. timeout is
# the "expected" bound, so it comes first -- like every other minitest predicate.
def dead_within?(timeout, pid)
  deadline = monotonic + timeout
  sleep 0.02 while running?(pid) && monotonic < deadline
  !running?(pid)
end

class HolderTest < Minitest::Test
  include FileUtils

  parallelize_me!

  TEST_TIMEOUT = 3
  LEAK_CYCLES = 50

  # bound every test (plus its setup/teardown) so a wedged child can never hang
  # the suite -- a timeout surfaces as an ordinary failure on that test alone.
  def capture_exceptions
    super { Timeout.timeout(TEST_TIMEOUT) { yield } }
  end

  def setup
    @procs = [] # Holder handles -> terminate
    @pids  = [] # raw [pid, group?] -> kill
    @ios   = [] # IOs -> close
    @paths = [] # files/dirs -> remove
  end

  # all cleanup lives here, registered by the track_* helpers below, so no test
  # body needs an ensure block just to tidy up after itself.
  def teardown
    @procs.each { |h| silently { h.terminate(grace: 0.2) } }
    @pids.each do |pid, group|
      next if pid.to_i <= 0 # never signal pid 0 -- that hits our own group

      silently { Process.kill(group ? "-KILL" : "KILL", pid) }
    end
    @ios.each   { |io| silently { io.close } }
    @paths.each { |path| silently { remove_entry(path) } }
  end

  # ---- resource tracking (teardown does the cleanup, not the test) ---------

  def silently
    yield
  rescue StandardError
    nil
  end

  def track_pid(pid, group: false)
    @pids << [pid, group]
    pid
  end

  def track_io(io)
    @ios << io
    io
  end

  def track_path(path)
    @paths << path
    path
  end

  def spawn(*cmd, **kw)
    h = Holder::Tenant.new(*cmd, **kw).run
    @procs << h
    h
  end

  def tmpfile
    track_path("/tmp/holder_#{$PROCESS_ID}_#{rand(1_000_000)}.txt")
  end

  def open_tmp(mode)
    track_io(File.open(tmpfile, mode))
  end

  def tmpdir
    path = "/tmp/holder_#{$PROCESS_ID}_#{rand(1_000_000)}"
    mkdir(path)
    track_path(path)
  end

  def input_io(content)
    path = tmpfile
    File.write(path, content)
    track_io(File.open(path, "r"))
  end

  def pipe
    IO.pipe.each { |io| track_io(io) }
  end

  def elapsed
    start = monotonic
    yield
    monotonic - start
  end

  # ---- custom assertions (keep the test bodies free of naked assert/refute) -

  def assert_running(pid, msg = nil)
    assert running?(pid), msg || "expected pid #{pid} to be running"
  end

  def refute_running(pid, msg = nil)
    refute running?(pid), msg || "expected pid #{pid} not to be running"
  end

  def assert_dead_within(timeout, pid, msg = nil)
    assert dead_within?(timeout, pid),
           msg || "expected pid #{pid} to be dead within #{timeout}s"
  end

  def assert_all_closed(ios, msg = nil)
    assert_empty ios.reject(&:closed?), msg || "expected every IO to be closed"
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

  # in: pump closes stdin -> filter sees EOF, exits
  def test_stdin_from_io_completes_no_hang
    f = open_tmp("w")
    dt = elapsed { Holder::Tenant.new("sort", in: input_io("b\na\nc\n"), out: f).run.wait }
    f.close

    assert_operator dt, :<, 3, "must not hang"
    assert_equal "a\nb\nc", File.read(f.path).chomp
  end

  # was a missing matrix branch (-> popen3)
  def test_in_only_combo
    out = Holder::Tenant.new("cat", in: input_io("solo\n")).run { |io| io.stdout.read }

    assert_equal "solo", out.chomp
  end

  # the other missing branch (-> popen2, err direct)
  def test_in_plus_err_combo
    f = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "cat 1>&2", in: input_io("toerr\n"), err: f).run.wait
    f.close

    assert_equal "toerr", File.read(f.path).chomp
  end

  def test_works_block_form_auto_teardown
    pid = nil
    Holder::Tenant.new("sh", "-c", "sleep 30").run { |io| pid = io.pid }
    track_pid(pid, group: true)

    assert_dead_within 2, pid, "block form should tear the process down on exit"
  end

  # popen3 pipes stdout; we pump it to the file
  def test_works_direct_out_redirect_via_pump
    f = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "echo to_file", out: f).run.wait # run to completion
    f.close

    assert_equal "to_file", File.read(f.path).chomp
  end

  # popen2 honors err: directly (no pipe, no pump)
  def test_works_direct_err_redirect
    f = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "echo oops 1>&2", err: f).run.wait
    f.close

    assert_equal "oops", File.read(f.path).chomp
  end

  def test_block_form_tears_down_no_block_form_does_not
    # block form: process is gone once the block returns
    bpid = nil
    Holder::Tenant.new("sh", "-c", "sleep 30").run { |io| bpid = io.pid }
    track_pid(bpid, group: true)

    assert_dead_within 2, bpid, "block form should tear down on block exit"

    # no-block form: process keeps running until YOU tear it down
    h = spawn("sh", "-c", "sleep 30")
    sleep 0.1

    assert_running h.pid, "no-block form must NOT auto-tear-down; caller owns it"
    h.terminate(grace: 0.5)

    refute_running h.pid
  end

  # ---- the old flaws, now fixed (green = bug gone) -------------------------

  # flaw #2
  def test_fixed_no_esrch_when_already_exited
    h = spawn("true")
    sleep 0.02 while running?(h.pid)
    status = h.terminate # must NOT raise Errno::ESRCH

    assert_kind_of ::Process::Status, status
  end

  # flaw #3a/#3b: ignores TERM -> still dies, fast
  def test_fixed_sigkill_escalation
    h = spawn("sh", "-c", 'trap "" TERM; while :; do sleep 1; done')
    pid = h.pid
    took = elapsed { h.terminate(grace: 0.5) }

    refute_running pid, "TERM-ignoring process should be SIGKILLed"
    assert_operator took, :<, 3, "should escalate after grace, not hang"
  end

  # terminate from another thread is safe
  def test_fixed_cross_thread_teardown
    h = spawn("sh", "-c", "sleep 30")
    pid = h.pid
    err = nil
    Thread.new do
      h.terminate(grace: 0.5)
    rescue StandardError => e
      err = e
    end.join

    assert_nil err, "cross-thread terminate must not raise"
    refute_running pid
  end

  # group teardown reaches the shell-backgrounded grandchild. the grandchild
  # sleeps far longer than the test window, so self-exit can never mask a miss.
  def test_fixed_backgrounded_grandchild_reaped
    h = spawn("sh", "-c", "sleep 300 & echo $!; sleep 300")
    bg_pid = track_pid(h.stdout.gets.to_i)

    assert_running bg_pid, "sanity: backgrounded grandchild should be alive"
    h.terminate(grace: 0.5)

    assert_dead_within 2, bg_pid, "group teardown should kill the backgrounded grandchild"
  end

  # leader exits immediately, orphaning a grandchild that still holds the dead
  # leader's pgid -- terminate must still signal the group, not skip it
  def test_terminate_signals_group_when_leader_already_exited
    h = Holder::Tenant.new("sh", "-c", "sleep 300 & echo $!").run # sh backgrounds, then returns
    @procs << h
    gc = track_pid(h.stdout.gets.to_i)
    sleep 0.25 # let the leader exit

    assert_running gc, "sanity: orphaned grandchild should be alive"
    h.terminate(grace: 0.5)

    assert_dead_within 2, gc, "terminate must signal the group even after the leader has exited"
  end

  def test_fixed_double_terminate_idempotent
    h = spawn("sh", "-c", "sleep 30")
    a = h.terminate(grace: 0.5)
    b = h.terminate(grace: 0.5)

    assert_same a, b, "second terminate returns the same cached status, no raise"
    assert_all_closed [h.stdin, h.stdout, h.stderr], "pipes should be closed"
  end

  def test_handle_hygiene_hides_internals_and_redirected_streams
    f = open_tmp("w")
    h = spawn("sh", "-c", "echo hi; sleep 5", out: f) # out redirected, err/in not

    assert_nil h.stdout, "a redirected stream must not expose its internal pipe"
    refute_nil h.stderr, "an un-redirected stream stays a usable pipe"
    assert_kind_of Integer, h.pid
    %i[pump_threads owned_ios wait_thread mutex].each do |internal|
      refute_respond_to h, internal, "#{internal} is plumbing and must stay internal"
    end
    h.terminate(grace: 0.5)
  end

  # flaw #4: INT-ignoring process no longer survives teardown
  def test_fixed_interrupt_also_escalates
    h = spawn("sh", "-c", 'trap "" INT; while :; do sleep 1; done')
    pid = h.pid
    h.interrupt(grace: 0.5)

    refute_running pid, "INT-ignoring process should be SIGKILLed by interrupt's escalation"
  end

  # ---- production: resource accounting & error paths -----------------------

  def test_no_fd_or_thread_leak_over_many_cycles
    GC.start
    sleep 0.1
    fds0 = fd_count
    thr0 = Thread.list.size
    LEAK_CYCLES.times { Holder::Tenant.new("sh", "-c", "echo hi").run { |io| io.stdout.read } }
    LEAK_CYCLES.times do
      f = open_tmp("w")
      Holder::Tenant.new("sh", "-c", "echo hi", out: f).run(&:wait)
      f.close
    end
    LEAK_CYCLES.times { Holder::Tenant.new("cat", in: input_io("x\n")).run { |io| io.stdout.read } }
    GC.start
    sleep 0.4

    assert_operator fd_count - fds0, :<=, 2, "fds must not grow across spawn/teardown cycles"
    assert_operator Thread.list.size - thr0, :<=, 2, "threads must not grow across cycles"
  end

  def test_block_form_cleans_up_when_block_raises
    pid = nil
    assert_raises(RuntimeError) do
      Holder::Tenant.new("sh", "-c", "sleep 30").run do |io|
        pid = io.pid
        raise "boom"
      end
    end
    track_pid(pid, group: true)

    assert_dead_within 2, pid, "ensure must tear the child down even when the block raises"
  end

  # a redirect failing mid-copy
  def test_pump_error_is_captured_not_raised
    src = StringIO.new("data")
    bad = Object.new

    # stand-in for ENOSPC/EIO on write
    def bad.write(*) = raise("disk full")

    thread = Holder::Tenant.allocate.send(:pump, src, bad)

    assert_kind_of RuntimeError, thread.value, "pump must capture the error as its value, not raise"
  end

  def test_pump_error_does_not_block_pipe_close
    r, w = pipe
    _, _, _, wait = Open3.popen3("true") # a real, short-lived wait_thread
    failed = Thread.new { RuntimeError.new("disk full") } # a pump that finished with an error
    h = Holder::Handle.new(
      stdin: nil, stdout: nil, stderr: nil,
      wait_thread: wait, pump_threads: [failed], owned_ios: [r, w]
    )
    h.terminate(grace: 0.5)

    assert_all_closed [r, w], "owned pipes must close even when a pump errored"
    assert_kind_of RuntimeError, h.pump_error, "the pump error is surfaced on the handle"
  end

  # dropping a no-block handle without terminate/wait leaks the process -- this
  # pins that contract so it can't silently change
  def test_dropped_no_block_handle_leaks_until_terminated
    pid = track_pid(Holder::Tenant.new("sh", "-c", "sleep 30").run.pid, group: true) # handle goes out of scope
    GC.start
    sleep 0.2

    assert_running pid, "no-block handle isn't auto-reaped; caller must tear it down"
  end

  # ---- regression: reviewer findings ---------------------------------------

  # finding #1
  def test_matcher_lives_under_holder_not_core_io
    refute_includes ::IO.constants, :InputStreamType, "must not patch core ::IO"
    assert_includes Holder.constants, :StreamType, "the matcher belongs under Holder"
  end

  # finding #2
  def test_matcher_rejects_non_io_arguments
    [0, 1, 2, 64, "/dev/null", "log.txt", :stdin, StringIO.new("x")].each do |bad|
      refute_operator Holder::StreamType, :===, bad, "#{bad.inspect} is not an IO and must be rejected"
    end
    f = open_tmp("w")

    [$stdin, $stdout, f].each do |good|
      assert_operator Holder::StreamType, :===, good, "#{good.class} is a real IO and must be accepted"
    end
  end

  # finding #3 (no silent detonation)
  def test_run_rejects_non_io_redirect_up_front
    assert_raises(ArgumentError) { Holder::Tenant.new("cat", in: 0).run }
    assert_raises(ArgumentError) { Holder::Tenant.new("cat", out: "log.txt").run }
    assert_raises(ArgumentError) { Holder::Tenant.new("cat", err: StringIO.new).run }
  end

  # finding #4
  def test_kwargs_forwarded_to_spawn
    dir = tmpdir
    f = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "pwd", out: f, chdir: dir).run.wait
    f.close

    assert_equal dir, File.read(f.path).strip, "chdir kwarg must reach spawn"
  end

  # our pgroup:true must win. the grandchild sleeps far longer than the test
  # window, so the ONLY way it can die in time is the group signal -- a stray
  # self-exit can't masquerade as a pass, and an alive grandchild fails fast.
  def test_kwargs_cannot_override_pgroup
    h = Holder::Tenant.new("sh", "-c", "sleep 300 & echo $!; sleep 300", pgroup: false).run
    @procs << h
    gc = track_pid(h.stdout.gets.to_i)

    assert_running gc, "sanity: backgrounded grandchild should be alive"
    h.terminate(grace: 0.5)

    assert_dead_within 2, gc, "pgroup:true must win so teardown reaches the group"
  end

  # finding #5
  def test_wait_does_not_starve_terminate
    h = spawn("sh", "-c", "sleep 30")
    waiter = Thread.new { h.wait }
    sleep 0.2
    dt = elapsed { h.terminate(grace: 0.5) }
    waiter.join

    assert_operator dt, :<, 2.0, "terminate must not block behind a concurrent wait (took #{dt.round(2)}s)"
  end

  # found while testing #2/#3
  def test_terminate_bounded_with_never_eof_input
    r, w = pipe
    w.write("partial, no EOF\n") # writer kept open -> r never EOFs
    h = Holder::Tenant.new("cat", in: r).run
    @procs << h
    sleep 0.2
    dt = elapsed { h.terminate(grace: 0.5) }

    assert_operator dt, :<, Holder::Handle::PUMP_GRACE + 2,
                    "an in: pump stuck on a non-EOF source must not wedge terminate (took #{dt.round(2)}s)"
  end
end

