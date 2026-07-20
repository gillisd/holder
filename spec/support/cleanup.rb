require "fileutils"
require "timeout"

##
# Collects teardown actions (kill a pid/group, close an IO, remove a path,
# terminate a handle) and runs them in reverse order, best-effort, so one
# failing action never blocks the rest -- whether it fails by raising or by
# never returning.
class Cleanup
  # seconds a single action may take before it is abandoned. Generous next to
  # the terminate(grace: 0.2) that #process defers, so only a genuinely wedged
  # action is ever cut short.
  ACTION_GRACE = 5

  def initialize(action_grace: ACTION_GRACE)
    @deferred = []
    @action_grace = action_grace
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
    # Best-effort teardown: one action failing (a pid already reaped, an IO
    # already closed, a path already gone) must never stop the rest from running,
    # so every error is deliberately swallowed -- the contract verified by
    # "#run when one deferred action raises keeps undoing the rest".
    #
    # A HANGING action is bounded for the same reason, and it is not a
    # hypothetical: the teardown a wedged example leaves behind is a handle
    # whose terminate is the very thing that hung. The example's own watchdog is
    # no help there -- it fires once, inside the example, and by the time this
    # hook runs it has already gone off -- so without this bound a wedged
    # teardown strands the whole run with nothing left to interrupt it.
    @deferred.reverse_each do |action|
      begin
        Timeout.timeout(@action_grace) { action.call }
      rescue StandardError # rubocop:disable Claude/NoOverlyDefensiveCode
        nil
      end
    end
  end

  private

  def defer(&action)
    @deferred << action
  end
end
