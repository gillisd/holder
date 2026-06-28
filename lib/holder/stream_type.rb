module Holder
  ##
  # Type matcher for the +in:+/+out:+/+err:+ redirect arguments. Defined under
  # +Holder+ -- NOT core <tt>::IO</tt> -- and matches only real IO instances
  # (<tt>$stdin</tt>/<tt>$stdout</tt>/<tt>$stderr</tt>, File, pipe ends). Integer
  # fds, path strings, StringIO, Tempfile and other duck types are rejected at
  # validation, so a stray <tt>run(in: 0)</tt> raises up front instead of slipping
  # through and detonating later inside a pump.
  module StreamType
    def self.===(other) = other.is_a?(::IO)
  end
end
