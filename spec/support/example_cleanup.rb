##
# The teardown registry for one example. Every helper that opens a pipe, writes
# a tmpfile, or spawns a child registers the undo here, and spec_helper runs it
# after the example -- so a spec that fails mid-scenario still leaves no child,
# pipe, or file behind.
module ExampleCleanup
  def cleanup
    @cleanup ||= Cleanup.new
  end
end
