require "fileutils"

##
# Collects teardown actions (kill a pid/group, close an IO, remove a path,
# terminate a handle) and runs them in reverse order, best-effort, so one
# failing action never blocks the rest.
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
    rescue StandardError # rubocop:disable Claude/NoOverlyDefensiveCode
      nil
    end
  end

  private

  def defer(&action)
    @deferred << action
  end
end
