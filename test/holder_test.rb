require "test_helper"
require "English"
require "open3"
require "stringio"
require "fileutils"
require "timeout"

class HolderTest < Minitest::Test
  include FileUtils

  module Clock
    def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

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

  class Cleanup
    def initialize
      @deferred = []
    end

    def process(handle)
      defer { handle.terminate(grace: 0.2) }
      handle
    end

    def pid(pid, group: false)
      pid = pid.to_i
      defer { Process.kill(group ? "-KILL" : "KILL", pid) } if pid.positive?
      pid
    end

    def io(io)
      defer { io.close }
      io
    end

    def path(path)
      defer { FileUtils.remove_entry(path) }
      path
    end

    def run
      @deferred.reverse_each do |action|
        action.call
      rescue StandardError
        nil
      end
    end

    private

    def defer(&action)
      @deferred << action
    end
  end

  class AlwaysFailingWriter
    def write(*) = raise("disk full")
  end

  parallelize_me!

  TEST_TIMEOUT = 3
  LEAK_CYCLES = 30
  OUTLIVES_TEST = 300

  def capture_exceptions(&)
    super { Timeout.timeout(TEST_TIMEOUT, &) }
  end

  def setup
    @cleanup = Cleanup.new
  end

  def teardown
    @cleanup.run
  end

  def spawn(*cmd, **kw)
    @cleanup.process(Holder::Tenant.new(*cmd, **kw).run)
  end

  def tmpfile
    @cleanup.path("/tmp/holder_#{$PROCESS_ID}_#{rand(1_000_000)}.txt")
  end

  def open_tmp(mode)
    @cleanup.io(File.open(tmpfile, mode))
  end

  def tmpdir
    path = "/tmp/holder_#{$PROCESS_ID}_#{rand(1_000_000)}"
    mkdir(path)
    @cleanup.path(path)
  end

  def input_io(content)
    path = tmpfile
    File.write(path, content)
    @cleanup.io(File.open(path, "r"))
  end

  def pipe
    IO.pipe.each { |io| @cleanup.io(io) }
  end

  def never_eof_source
    reader, writer = pipe
    writer.write("partial, no EOF\n")
    reader
  end

  def fd_count
    Pathname.new("/proc/#{Process.pid}/fd").children.size
  end

  def elapsed
    start = Clock.monotonic
    yield
    Clock.monotonic - start
  end

  def live_pid_from(io)
    pid = @cleanup.pid(io.gets.to_i)

    assert_running pid
    pid
  end

  def wait_for_exit(pid)
    probe = ProcessProbe.new(pid)
    sleep 0.02 while probe.alive?
  end

  def error_raised_in_thread
    Thread.new do
      yield
      nil
    rescue StandardError => e
      e
    end.value
  end

  def churn_processes(n)
    n.times { Holder::Tenant.new("sh", "-c", "echo hi").run { |io| io.stdout.read } }
    n.times do
      f = open_tmp("w")
      Holder::Tenant.new("sh", "-c", "echo hi", out: f).run(&:wait)
      f.close
    end
    n.times do
      i = input_io("x\n")
      Holder::Tenant.new("cat", in: i).run { |io| io.stdout.read }
      i.close
    end
  end

  def reaped_wait_thread
    stdin, stdout, stderr, wait = Open3.popen3("true")
    [stdin, stdout, stderr].each(&:close)
    wait
  end

  def handle_with_failed_pump(owned_ios:)
    Holder::Handle.new(
      stdin: nil, stdout: nil, stderr: nil,
      wait_thread: reaped_wait_thread,
      pump_threads: [Thread.new { RuntimeError.new("disk full") }],
      owned_ios: owned_ios
    )
  end

  def assert_running(pid, msg = nil)
    assert_predicate ProcessProbe.new(pid), :alive?, msg || "expected pid #{pid} to be running"
  end

  def refute_running(pid, msg = nil)
    refute_predicate ProcessProbe.new(pid), :alive?, msg || "expected pid #{pid} not to be running"
  end

  def assert_dead_within(timeout, pid, msg = nil)
    assert ProcessProbe.new(pid).dead_within?(timeout),
           msg || "expected pid #{pid} to die within #{timeout}s"
  end

  def assert_all_closed(ios, msg = nil)
    assert_empty ios.reject(&:closed?), msg || "expected every IO to be closed"
  end

  def test_that_it_has_a_version_number
    refute_nil Holder::VERSION
  end

  def test_no_block_form_exposes_readable_stdout
    h = spawn("sh", "-c", "echo hello")

    assert_equal "hello", h.stdout.gets&.chomp
  end

  def test_in_redirect_sorts_input_to_eof
    out = open_tmp("w")
    Holder::Tenant.new("sort", in: input_io("b\na\nc\n"), out: out).run.wait
    out.close

    assert_equal "a\nb\nc", File.read(out.path).chomp
  end

  def test_in_redirect_without_out_or_err_pipes_stdout
    output = Holder::Tenant.new("cat", in: input_io("solo\n")).run { |io| io.stdout.read }

    assert_equal "solo", output.chomp
  end

  def test_in_and_err_redirect_routes_stderr_to_file
    err = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "cat 1>&2", in: input_io("toerr\n"), err: err).run.wait
    err.close

    assert_equal "toerr", File.read(err.path).chomp
  end

  def test_out_redirect_writes_child_stdout_to_file
    out = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "echo to_file", out: out).run.wait
    out.close

    assert_equal "to_file", File.read(out.path).chomp
  end

  def test_err_redirect_writes_child_stderr_to_file
    err = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "echo oops 1>&2", err: err).run.wait
    err.close

    assert_equal "oops", File.read(err.path).chomp
  end

  def test_block_form_tears_down_child_on_block_exit
    pid = nil
    Holder::Tenant.new("sh", "-c", "sleep #{OUTLIVES_TEST}").run { |io| pid = io.pid }
    @cleanup.pid(pid, group: true)

    assert_dead_within 2, pid
  end

  def test_block_form_tears_down_child_when_block_raises
    pid = nil
    assert_raises(RuntimeError) do
      Holder::Tenant.new("sh", "-c", "sleep #{OUTLIVES_TEST}").run do |io|
        pid = io.pid
        raise "boom"
      end
    end
    @cleanup.pid(pid, group: true)

    assert_dead_within 2, pid
  end

  def test_dropped_handle_is_not_auto_reaped
    pid = @cleanup.pid(Holder::Tenant.new("sh", "-c", "sleep #{OUTLIVES_TEST}").run.pid, group: true)
    GC.start
    sleep 0.2

    assert_running pid
  end

  def test_terminate_on_exited_child_returns_status
    h = spawn("true")
    wait_for_exit(h.pid)

    assert_kind_of ::Process::Status, h.terminate
  end

  def test_double_terminate_returns_the_same_status
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST}")
    first = h.terminate(grace: 0.5)

    assert_same first, h.terminate(grace: 0.5)
  end

  def test_terminate_closes_the_handle_pipes
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST}")
    h.terminate(grace: 0.5)

    assert_all_closed [h.stdin, h.stdout, h.stderr]
  end

  def test_term_ignoring_child_is_force_killed
    h = spawn("sh", "-c", 'trap "" TERM; while :; do sleep 1; done')
    pid = h.pid
    h.terminate(grace: 0.5)

    refute_running pid
  end

  def test_int_ignoring_child_is_force_killed_by_interrupt
    h = spawn("sh", "-c", 'trap "" INT; while :; do sleep 1; done')
    pid = h.pid
    h.interrupt(grace: 0.5)

    refute_running pid
  end

  def test_terminate_from_a_non_owning_thread_does_not_raise
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST}")

    assert_nil(error_raised_in_thread { h.terminate(grace: 0.5) })
  end

  def test_terminate_is_not_blocked_by_a_concurrent_wait
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST}")
    waiter = Thread.new { h.wait }
    Thread.pass until waiter.status == "sleep"
    duration = elapsed { h.terminate(grace: 0.5) }
    waiter.join

    assert_operator duration, :<, 2.0
  end

  def test_terminate_is_bounded_when_in_source_never_eofs
    h = @cleanup.process(Holder::Tenant.new("cat", in: never_eof_source).run)
    sleep 0.2
    duration = elapsed { h.terminate(grace: 0.5) }

    assert_operator duration, :<, Holder::Handle::PUMP_GRACE + 2
  end

  def test_group_teardown_kills_backgrounded_grandchild
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST} & echo $!; sleep #{OUTLIVES_TEST}")
    grandchild = live_pid_from(h.stdout)
    h.terminate(grace: 0.5)

    assert_dead_within 2, grandchild
  end

  def test_terminate_signals_group_after_leader_has_exited
    h = @cleanup.process(Holder::Tenant.new("sh", "-c", "sleep #{OUTLIVES_TEST} & echo $!").run)
    grandchild = live_pid_from(h.stdout)
    wait_for_exit(h.pid)
    h.terminate(grace: 0.5)

    assert_dead_within 2, grandchild
  end

  def test_pgroup_true_cannot_be_overridden_by_kwargs
    h = @cleanup.process(
      Holder::Tenant.new("sh", "-c", "sleep #{OUTLIVES_TEST} & echo $!; sleep #{OUTLIVES_TEST}", pgroup: false).run,
    )
    grandchild = live_pid_from(h.stdout)
    h.terminate(grace: 0.5)

    assert_dead_within 2, grandchild
  end

  def test_redirected_stream_is_not_exposed_as_a_pipe
    h = spawn("sh", "-c", "echo hi; sleep #{OUTLIVES_TEST}", out: open_tmp("w"))

    assert_nil h.stdout
  end

  def test_unredirected_stream_remains_a_pipe
    h = spawn("sh", "-c", "echo hi; sleep #{OUTLIVES_TEST}", out: open_tmp("w"))

    refute_nil h.stderr
  end

  def test_handle_exposes_an_integer_pid
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST}")

    assert_kind_of Integer, h.pid
  end

  def test_handle_hides_internal_plumbing
    h = spawn("sh", "-c", "sleep #{OUTLIVES_TEST}")

    %i[pump_threads owned_ios wait_thread mutex].each do |internal|
      refute_respond_to h, internal
    end
  end

  def test_file_descriptors_do_not_leak_across_cycles
    GC.start
    before = fd_count
    churn_processes(LEAK_CYCLES)
    GC.start
    sleep 0.2

    assert_operator fd_count - before, :<=, 2
  end

  def test_threads_do_not_leak_across_cycles
    GC.start
    before = Thread.list.size
    churn_processes(LEAK_CYCLES)
    GC.start
    sleep 0.2

    assert_operator Thread.list.size - before, :<=, 2
  end

  def test_pump_captures_writer_error_as_its_value
    thread = Holder::Tenant.allocate.send(:pump, StringIO.new("data"), AlwaysFailingWriter.new)

    assert_kind_of RuntimeError, thread.value
  end

  def test_owned_pipes_close_even_when_a_pump_errored
    reader, writer = pipe
    handle = handle_with_failed_pump(owned_ios: [reader, writer])
    handle.terminate(grace: 0.5)

    assert_all_closed [reader, writer]
  end

  def test_handle_surfaces_the_pump_error
    handle = handle_with_failed_pump(owned_ios: pipe)
    handle.terminate(grace: 0.5)

    assert_kind_of RuntimeError, handle.pump_error
  end

  def test_stream_matcher_does_not_patch_core_io
    refute_includes ::IO.constants, :InputStreamType
  end

  def test_stream_matcher_is_defined_under_holder
    assert_includes Holder.constants, :StreamType
  end

  def test_stream_matcher_rejects_non_io_values
    [0, 1, 2, 64, "/dev/null", "log.txt", :stdin, StringIO.new("x")].each do |value|
      refute_operator Holder::StreamType, :===, value
    end
  end

  def test_stream_matcher_accepts_real_ios
    [$stdin, $stdout, open_tmp("w")].each do |io|
      assert_operator Holder::StreamType, :===, io
    end
  end

  def test_run_rejects_non_io_redirects_immediately
    { in: 0, out: "log.txt", err: StringIO.new }.each do |stream, value|
      assert_raises(ArgumentError) { Holder::Tenant.new("cat", **{ stream => value }).run }
    end
  end

  def test_chdir_kwarg_is_forwarded_to_the_child
    dir = tmpdir
    out = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "pwd", out: out, chdir: dir).run.wait
    out.close

    assert_equal dir, File.read(out.path).strip
  end
end
