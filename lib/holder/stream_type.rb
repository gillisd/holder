module Holder
  module StreamType
    # Type matcher for the in:/out:/err: redirect arguments. Defined under Pb3 --
    # NOT core ::IO -- and matches only real IO instances ($stdin/$stdout/$stderr,
    # File, pipe ends). Integer fds, path strings, StringIO, Tempfile and other
    # duck types are rejected here at validation, so a stray `run(in: 0)` raises up
    # front instead of slipping through and detonating later inside a pump.
    def self.===(other) = other.is_a?(::IO)
  end
end
