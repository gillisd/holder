require "fileutils"

##
# Builds the IOs a supervised child reads and writes: tmpfiles and directories,
# pipes, a source that never reaches EOF, and sinks that are slow or wedged
# outright. Everything opened here registers its undo with the example's
# +cleanup+ (see ExampleCleanup), so nothing survives the example.
module IoHelpers
  def tmpfile
    cleanup.path("/tmp/holder_#{Process.pid}_#{rand(1_000_000)}.txt")
  end

  def open_tmp(mode)
    cleanup.io(File.open(tmpfile, mode))
  end

  def tmpdir
    path = "/tmp/holder_#{Process.pid}_#{rand(1_000_000)}"
    FileUtils.mkdir(path)
    cleanup.path(path)
  end

  # A named pipe a child can block on in-process with `read <> fifo`: opening it
  # read-write makes the child its own writer, so the read blocks (never hits
  # EOF) with no forked `sleep` for a signal to race during its fork/exec.
  def blocking_fifo
    path = "/tmp/holder_#{Process.pid}_#{rand(1_000_000)}.fifo"
    File.mkfifo(path)
    cleanup.path(path)
  end

  def input_io(content)
    path = tmpfile
    File.write(path, content)
    cleanup.io(File.open(path, "r"))
  end

  def make_pipe
    IO.pipe.each { |io| cleanup.io(io) }
  end

  def never_eof_source
    reader, writer = make_pipe
    writer.write("partial, no EOF\n")
    reader
  end

  # Stuff a pipe's write end until it would block, so the next write into it --
  # like a pump delivering child output -- stalls until the reader drains it.
  def fill_pipe(writer)
    chunk = "x" * 4096
    loop { break unless writer.write_nonblock(chunk, exception: false).is_a?(Integer) }
  end

  def drain_zero_bytes(reader, wanted, deadline:)
    zeros = 0
    while zeros < wanted && Clock.monotonic < deadline
      next unless reader.wait_readable(0.05)

      data = reader.read_nonblock(65_536, exception: false)
      zeros += data.bytes.count(0) if data.is_a?(String)
    end
    zeros
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

  # /dev/fd lists the current process's open descriptors on both Linux (a
  # symlink to /proc/self/fd) and macOS (a devfs), so it counts FDs portably.
  def fd_count
    Dir.children("/dev/fd").size
  end
end
