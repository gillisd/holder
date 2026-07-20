RSpec.describe "interrupting a terminate that has already armed its escalation deadline" do
  # A child that ignores TERM, so the terminate is guaranteed to still be sitting
  # inside its grace window -- deadline armed, nothing escalated yet -- when the
  # Interrupt lands. `exec` hands the ignored TERM disposition straight to sleep,
  # so the shell is not left in front as a second process that could answer the
  # signal on the group's behalf. It prints ready only AFTER the trap is
  # installed, so the spec can never signal into the window before it exists.
  #
  # let! rather than let, and that is load-bearing: the first reference to the
  # handle is inside the terminating thread, so a lazy let would fork the child
  # there and start the 0.3s clock before it even exists. Under load the
  # Interrupt then lands while the thread is still staging, terminate is never
  # called at all, and the example goes green having exercised nothing.
  let!(:handle) do
    child_ignoring_term = spawn_process("sh", "-c", %(trap "" TERM; echo ready; exec sleep #{outlives_example}))
    child_ignoring_term.stdout.gets

    child_ignoring_term
  end

  # report_on_exception is off because the Interrupt IS the scenario, not a
  # surprise -- otherwise ruby prints the backtrace of a thread dying exactly as
  # intended. The thread is polled to completion rather than joined: join would
  # re-raise that Interrupt in the example's own thread.
  def interrupt_terminate_mid_grace
    terminating = Thread.new { handle.terminate(grace: 5) }
    terminating.report_on_exception = false
    sleep 0.3
    terminating.raise(Interrupt)
    Thread.pass while terminating.alive?
  end

  # Reaching in with instance_variable_get is deliberate: the escalation deadline
  # is private state with no public reader, and disarming it is the whole
  # contract here, so the ivar is the only thing there is to observe.
  it "clears @kill_deadline so a later teardown starts from a fresh clock" do
    interrupt_terminate_mid_grace

    expect(handle.instance_variable_get(:@kill_deadline)).to be_nil
  end
end
