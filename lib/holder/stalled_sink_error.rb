module Holder
  ##
  # Recorded in <tt>Handle#pump_error</tt> when +wait+ gave up on a redirected
  # +out:+ sink that would not drain within its +drain_grace+: the sink's pump
  # was interrupted and the child's still-buffered output discarded, so the
  # redirect is incomplete. A healthy sink that is merely slower than the
  # default can be granted more patience via <tt>wait(drain_grace:)</tt>.
  class StalledSinkError < Error
    def initialize(drain_grace)
      super("out: sink still undrained after #{drain_grace}s; remaining output discarded")
    end
  end
end
