require "zeitwerk"

##
# Top-level namespace for the holder gem.
#
# All constants under +Holder+ (Error, StalledSinkError, Tenant, Handle,
# StreamType) live in their own files under <tt>lib/holder/</tt> and are
# autoloaded by Zeitwerk -- there are no +require+ statements for local files.
module Holder
  LOADER = Zeitwerk::Loader.for_gem
  LOADER.setup
end
