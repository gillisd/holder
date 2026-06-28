require "test_helper"
require "stringio"
require "minitest/mock"

class CleanupTest < Minitest::Test
  def test_run_executes_deferred_actions_in_reverse_order
    removed = []
    FileUtils.stub(:remove_entry, ->(path) { removed << path }) do
      cleanup = Cleanup.new
      cleanup.path("first")
      cleanup.path("second")
      cleanup.run
    end

    assert_equal %w[second first], removed
  end

  def test_run_continues_after_an_action_raises
    removed = []
    remover = ->(path) { path == "explode" ? raise("boom") : removed << path }
    FileUtils.stub(:remove_entry, remover) do
      cleanup = Cleanup.new
      cleanup.path("bottom")
      cleanup.path("explode")
      cleanup.path("top")
      cleanup.run
    end

    assert_equal %w[top bottom], removed
  end

  def test_io_closes_the_registered_io_on_run
    io = StringIO.new("data")
    cleanup = Cleanup.new

    assert_same io, cleanup.io(io)
    cleanup.run

    assert_predicate io, :closed?
  end

  def test_pid_returns_the_pid_coerced_to_an_integer
    assert_equal 123, Cleanup.new.pid("123")
  end

  def test_pid_kills_a_positive_pid_on_run
    recorded = record_kills do |cleanup|
      cleanup.pid(123)
      cleanup.run
    end

    assert_equal [["KILL", 123]], recorded
  end

  def test_pid_signals_the_whole_group_when_group_is_true
    recorded = record_kills do |cleanup|
      cleanup.pid(123, group: true)
      cleanup.run
    end

    assert_equal [["-KILL", 123]], recorded
  end

  def test_pid_never_signals_a_nonpositive_pid
    recorded = record_kills do |cleanup|
      cleanup.pid(0)
      cleanup.pid(-5)
      cleanup.run
    end

    assert_empty recorded
  end

  def test_process_returns_the_handle
    handle = Object.new

    assert_same handle, Cleanup.new.process(handle)
  end

  def test_process_terminates_the_handle_on_run
    handle = Minitest::Mock.new
    handle.expect(:terminate, nil, grace: 0.2)
    cleanup = Cleanup.new

    cleanup.process(handle)
    cleanup.run
    handle.verify
  end

  def test_path_removes_the_path_on_run
    removed = []
    FileUtils.stub(:remove_entry, ->(path) { removed << path }) do
      cleanup = Cleanup.new

      assert_equal "/tmp/holder_x", cleanup.path("/tmp/holder_x")
      cleanup.run
    end

    assert_equal ["/tmp/holder_x"], removed
  end

  private

  def record_kills
    recorded = []
    Process.stub(:kill, ->(signal, pid) { recorded << [signal, pid] }) do
      yield Cleanup.new
    end
    recorded
  end
end
