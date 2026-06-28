require "test_helper"

class ProcessProbeTest < Minitest::Test
  parallelize_me!

  def setup
    @pids = []
  end

  def teardown
    @pids.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_alive_is_true_for_a_running_process
    assert_predicate ProcessProbe.new(spawn_proc("sleep", "300")), :alive?
  end

  def test_alive_is_false_for_a_nonpositive_pid
    refute_predicate ProcessProbe.new(0), :alive?
    refute_predicate ProcessProbe.new(-1), :alive?
  end

  def test_alive_is_false_after_the_process_is_reaped
    pid = spawn_proc("sleep", "300")
    Process.kill("KILL", pid)
    Process.wait(pid)

    refute_predicate ProcessProbe.new(pid), :alive?
  end

  def test_alive_treats_a_zombie_as_dead
    pid = spawn_proc("true")
    wait_until_zombie(pid)

    refute_predicate ProcessProbe.new(pid), :alive?
  end

  def test_dead_within_is_true_when_the_process_exits_in_time
    pid = spawn_proc("sleep", "0.2")

    assert ProcessProbe.new(pid).dead_within?(2)
  end

  def test_dead_within_is_false_when_the_process_outlives_the_timeout
    refute ProcessProbe.new(spawn_proc("sleep", "300")).dead_within?(0.2)
  end

  private

  def spawn_proc(*cmd)
    Process.spawn(*cmd).tap { |pid| @pids << pid }
  end

  def wait_until_zombie(pid)
    100.times do
      break if zombie?(pid)

      sleep 0.01
    end
  end

  def zombie?(pid)
    File.read("/proc/#{pid}/status")[/State:\s*(\w)/, 1] == "Z"
  rescue SystemCallError
    false
  end
end
