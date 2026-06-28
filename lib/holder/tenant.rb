require "open3"

module Holder
  ##
  # Builds and launches a child process, returning a Handle that owns its teardown.
  #
  # +in:+, +out:+, and +err:+ each accept an IO (or +nil+) to redirect that stream
  # to; any other keyword (+chdir+, +umask+, ...) is forwarded to the spawn. The
  # child always runs in its own process group so the whole group can be torn down
  # together -- this is not overridable.
  class Tenant
    attr_reader :handle, :pgroup, :kwargs
    private attr_reader :args
    private attr_writer :handle

    def initialize(*args, in: nil, out: nil, err: nil, **kwargs)
      @args = args
      @io_defs = { in:, out:, err: }
      @pgroup = true
      @kwargs = kwargs
    end

    def run # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      # Validate the three streams up front. The one-line pattern match checks each
      # is an IO or nil (in: is a keyword, so it can't be named as a local); we then
      # read the values out by key. A bad stream raises ArgumentError here rather
      # than slipping through and detonating later inside a pump.
      unless @io_defs in { in: StreamType | nil, out: StreamType | nil, err: StreamType | nil }
        raise ArgumentError, "in:, out:, and err: must each be an IO object or nil"
      end

      u_sin, u_sout, u_serr = @io_defs.values_at(:in, :out, :err)

      # Open3 ALWAYS pipes stdin and stdout, so in:/out: are always pumped; err is
      # the only stream that can go direct, and only via popen2. So the entire
      # 8-case dispatch is just this, and the only thing handed to spawn directly
      # is a redirected err:. Any extra kwargs (chdir, umask, unsetenv_others,
      # close_others, ...) are forwarded to spawn; they go in first so our
      # pgroup: true and err redirect win on collision and the group-teardown
      # invariant is never overridden.
      meth = u_serr ? :popen2 : :popen3
      spawn_redirects = u_serr ? { err: u_serr } : {}
      combined_kwargs = kwargs.merge(spawn_redirects)

      # Each form uses its matching Open3 form: block -> Open3's block form (its
      # close+reap is a backstop under our kill); no-block -> Open3's non-block
      # form (the handle owns teardown).
      if block_given?
        Open3.public_send(meth, *args, pgroup:, **combined_kwargs) do |*streams|
          self.handle = build_handle(streams, meth, u_sin, u_sout, u_serr)
          begin
            yield handle
          ensure
            handle.terminate
          end
        end
      else
        streams = Open3.public_send(meth, *args, **kwargs, pgroup:, **spawn_redirects)
        self.handle = build_handle(streams, meth, u_sin, u_sout, u_serr)
      end
    end

    private

    def build_handle(streams, meth, u_sin, u_sout, u_serr)
      block_keys = meth == :popen3 ? %i[sin sout serr wait] : %i[sin sout wait]
      piped = block_keys.zip(streams).to_h
      sin_pipe = piped[:sin]
      sout_pipe = piped[:sout]
      serr_pipe = piped[:serr] # nil for popen2 (stderr isn't piped there)

      pumps = []
      # feed a redirected in: into the stdin pipe, then close it so the child
      # reads EOF and can exit on its own (Open3.capture3's `i.close`)
      pumps << pump(u_sin, sin_pipe, close_after: true) if u_sin
      # drain a redirected out: from the stdout pipe into the caller's IO
      pumps << pump(sout_pipe, u_sout) if u_sout
      # a redirected err: went direct via popen2 -- no pump

      Handle.new(
        # hide the internal pipe for any stream you redirected; you talk to your IO
        stdin: u_sin ? nil : sin_pipe,
        stdout: u_sout ? nil : sout_pipe,
        stderr: u_serr ? nil : serr_pipe,
        wait_thread: piped.fetch(:wait),
        pump_threads: pumps,
        owned_ios: [sin_pipe, sout_pipe, serr_pipe].compact,
      )
    end

    def pump(src, destination, close_after: false)
      Thread.new do
        IO.copy_stream(src, destination)
        nil
      rescue IOError, Errno::EPIPE, Errno::EBADF
        nil # source/dest torn down underneath us (the EPIPE Open3.capture3 swallows)
      rescue StandardError => e
        e # unexpected (e.g. ENOSPC writing a redirect); capture so teardown finishes
      ensure
        destination.close if close_after && !destination.closed?
      end
    end
  end
end
