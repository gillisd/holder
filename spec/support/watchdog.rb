##
# The per-example time budget the suite enforces around every spec.
#
# Two tiers, two purposes. A <tt>spec/unit</tt> example is the fast floor --
# pure logic, no process lifecycles -- so FAST is tight enough that an example
# which starts spawning children or sleeping fails instead of quietly slowing
# the edit-run loop; there it is a ceiling an example may lower but never raise.
# A <tt>spec/integration</tt> example stages real children, and INTEGRATION is
# deliberately tight enough to bound teardown itself. Most teardown examples
# assert liveness only AFTER terminate returns, so this budget is their only
# bound on how long terminate may take: a handle that delivers TERM correctly
# but then sits out a whole 5-second grace window has regressed, and this is
# what catches it. Loosening it is not free.
#
# An example whose own scripted work approaches the budget states a bigger one
# with <tt>it "...", timeout: 20</tt> -- sized to that work, and paired with an
# explicit expectation for whatever the budget stopped bounding.
module Watchdog
  FAST = 1
  INTEGRATION = 3

  ##
  # Seconds the example described by +metadata+ may run before the watchdog
  # fires. A unit example is capped at FAST regardless of what it asks for.
  def self.budget(metadata)
    requested = metadata[:timeout]
    return [requested || FAST, FAST].min if metadata[:tier] == :unit

    requested || INTEGRATION
  end
end
