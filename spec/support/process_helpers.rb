##
# Drives real child processes: spawning a tenant whose teardown is deferred to
# the example's +cleanup+, reading a grandchild's pid off a pipe, waiting out an
# exit, timing a teardown, and churning whole spawn/teardown cycles for the leak
# hunts.
module ProcessHelpers
  def spawn_process(*cmd, **kwargs)
    cleanup.process(Holder::Tenant.new(*cmd, **kwargs).run)
  end

  # Read a pid a child printed and confirm it is really running before a spec
  # asserts anything about killing it -- a spec that "killed" an already-dead
  # grandchild proves nothing.
  def live_pid_from(io)
    pid = cleanup.pid(io.gets.to_i)
    expect(ProcessProbe.new(pid)).to be_alive

    pid
  end

  def wait_for_exit(pid)
    probe = ProcessProbe.new(pid)
    sleep 0.02 while probe.alive?
  end

  def elapsed
    start = Clock.monotonic
    yield
    Clock.monotonic - start
  end

  def error_raised_in_thread
    Thread.new do
      yield
      nil
    rescue StandardError => e
      e
    end.value
  end

  # Full spawn/teardown cycles three ways over -- piped, out: redirected, in:
  # redirected -- so a descriptor or thread the handle forgets to release shows
  # up as growth against the process-global counts the leak specs sample.
  def churn_processes(count)
    count.times { churn_piped_cycle }
    count.times { churn_out_redirect_cycle }
    count.times { churn_in_redirect_cycle }
  end

  def churn_piped_cycle
    Holder::Tenant.new("sh", "-c", "echo hi").run { |handle| handle.stdout.read }
  end

  def churn_out_redirect_cycle
    file = open_tmp("w")
    Holder::Tenant.new("sh", "-c", "echo hi", out: file).run(&:wait)
    file.close
  end

  def churn_in_redirect_cycle
    source = input_io("x\n")
    Holder::Tenant.new("cat", in: source).run { |handle| handle.stdout.read }
    source.close
  end
end
