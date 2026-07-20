##
# The per-example time budget the suite enforces around every spec.
#
# Two tiers, two purposes. A <tt>spec/unit</tt> example is the fast floor --
# pure logic, no process lifecycles -- so FAST is tight enough that an example
# which starts spawning children or sleeping fails instead of quietly slowing
# the edit-run loop; there it is a ceiling an example may lower but never raise.
# A <tt>spec/integration</tt> example stages real children, so INTEGRATION is
# only a hang catcher, sized for the slowest CI runner rather than for the work,
# and a heavier example states its own budget with <tt>it "...", timeout: 20</tt>.
#
# Timing *contracts* -- "teardown returns within PUMP_GRACE + 2" -- belong in
# explicit expectations, never in this backstop: a budget that doubles as an
# assertion is the flake that took the macOS leg down.
module Watchdog
  FAST = 1
  INTEGRATION = 10

  ##
  # Seconds the example described by +metadata+ may run before the watchdog
  # fires. A unit example is capped at FAST regardless of what it asks for.
  def self.budget(metadata)
    requested = metadata[:timeout]
    return [requested || FAST, FAST].min if metadata[:tier] == :unit

    requested || INTEGRATION
  end
end
