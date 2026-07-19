##
# Helpers for driving real child processes in the integration specs: spawning a
# tenant whose teardown is deferred to the shared Cleanup, and building pipes
# that model a slow or wedged +out:+ sink.
module ProcessHelpers
  def cleanup
    @cleanup ||= Cleanup.new
  end

  def spawn_process(*cmd, **kwargs)
    cleanup.process(Holder::Tenant.new(*cmd, **kwargs).run)
  end

  def make_pipe
    IO.pipe.each { |io| cleanup.io(io) }
  end

  # Stuff a pipe's write end until it would block, so the next blocking write
  # into it -- like a pump delivering child output -- stalls until it is drained.
  def fill_pipe(writer)
    chunk = "x" * 4096
    loop { break unless writer.write_nonblock(chunk, exception: false).is_a?(Integer) }
  end

  # A real Process.detach wait thread whose "true" child has already exited and
  # been reaped, for building a Handle in isolation from a live leader.
  def reaped_wait_thread
    streams = Open3.popen3("true")
    streams.first(3).each(&:close)
    streams.last.tap(&:join)
  end
end
