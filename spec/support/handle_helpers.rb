require "open3"

##
# Builds a Handle directly around pumps that already failed, so the pump-error
# contract can be specified without racing a real child into a real error. The
# wait thread is pre-reaped: teardown finds the process already gone and reduces
# to exactly the part under test -- reaping pumps and closing owned pipes.
module HandleHelpers
  def reaped_wait_thread
    stdin, stdout, stderr, wait = Open3.popen3("true")
    [stdin, stdout, stderr].each(&:close)
    wait
  end

  # Constructed without a drain_pump: key at all, so the constructor default is
  # exercised by something -- Tenant always passes it explicitly, so nothing
  # else in the suite would notice it being made required or renamed.
  def handle_with_failed_pump(owned_ios:)
    Holder::Handle.new(
      stdin: nil, stdout: nil, stderr: nil,
      wait_thread: reaped_wait_thread,
      pump_threads: [Thread.new { RuntimeError.new("disk full") }],
      owned_ios:
    )
  end

  def handle_with_pumps(pump_threads:, drain_pump: nil, owned_ios: [])
    Holder::Handle.new(
      stdin: nil, stdout: nil, stderr: nil,
      wait_thread: reaped_wait_thread,
      pump_threads:, drain_pump:, owned_ios:
    )
  end
end
