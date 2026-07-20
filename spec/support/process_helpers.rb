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

  # Drain a wedged sink's read end until +text+ arrives, freeing a pump blocked
  # on writing into it; raises if +patience+ runs out first.
  def drain_until(reader, text, patience: 5)
    deadline = Clock.monotonic + patience
    buffer = +""
    until buffer.include?(text)
      raise "sink saw #{buffer.bytesize} bytes but never #{text.inspect}" if Clock.monotonic > deadline

      buffer << reader.readpartial(65_536) if reader.wait_readable(0.1)
    end
    buffer
  end
end
