require "zeitwerk"

##
# Top-level namespace for the holder gem.
module Holder
  LOADER = Zeitwerk::Loader.for_gem
  LOADER.setup

  ##
  # Base error class for holder.
  class Error < StandardError; end
end
