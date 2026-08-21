RSpec.describe "no supervised child outliving its host process" do
  # The invariant a process supervisor owes: a child must not outlive the host
  # that launched it -- however that host goes down. The block form already keeps
  # it, through its ensure (see tenant_block_form_spec, host_sigterm_teardown_spec).
  # The no-block form does NOT yet: it hands back a handle and installs nothing, so
  # a host that never tore the child down leaks it to init. Closing that requires a
  # process-wide at_exit backstop that reaps every still-live handle. Until it
  # exists these reaping examples are `pending` -- red on purpose, and they will
  # flip (and demand un-pending) the moment the backstop lands.
  #
  # Each host idles at a gate -- its stdin, or a sleep -- so the example can confirm
  # the child is up and then choose exactly when and how the host dies, with no race
  # in either the red state or the green one a backstop will produce.
  def unbuilt_backstop = "no process-exit backstop yet: a no-block host leaks its child"

  def no_block_host(idle:, then_exit: "")
    <<~RUBY
      $stdout.sync = true
      require "holder"
      handle = Holder::Tenant.new("sleep", "#{outlives_example}").run
      puts handle.pid
      #{idle}
      #{then_exit}
    RUBY
  end

  # Gated on stdin: the example ends the wait by closing it, so the host exits on
  # cue -- cleanly, or into an uncaught exception.
  def host_returning_normally = no_block_host(idle: "$stdin.gets")
  def host_dying_to_an_exception = no_block_host(idle: "$stdin.gets", then_exit: %(raise "boom"))
  # Gated on a sleep: the example ends the wait with a signal.
  def host_awaiting_a_signal = no_block_host(idle: "sleep #{outlives_example}")

  it "reaps the child when the host returns normally" do
    pending unbuilt_backstop
    host = spawn_ruby_host(host_returning_normally)
    child = live_pid_from(host.stdout)
    host.stdin.close

    expect(ProcessProbe.new(child)).to be_dead_within(1)
  end

  it "reaps the child when the host dies to an uncaught exception" do
    pending unbuilt_backstop
    host = spawn_ruby_host(host_dying_to_an_exception)
    child = live_pid_from(host.stdout)
    host.stdin.close

    expect(ProcessProbe.new(child)).to be_dead_within(1)
  end

  it "reaps the child when the host is sent SIGINT" do
    pending unbuilt_backstop
    host = spawn_ruby_host(host_awaiting_a_signal)
    child = live_pid_from(host.stdout)
    Process.kill("INT", host.pid)

    expect(ProcessProbe.new(child)).to be_dead_within(1)
  end

  it "reaps the child when the host is sent SIGTERM" do
    pending unbuilt_backstop
    host = spawn_ruby_host(host_awaiting_a_signal)
    child = live_pid_from(host.stdout)
    Process.kill("TERM", host.pid)

    expect(ProcessProbe.new(child)).to be_dead_within(1)
  end

  context "when the host is SIGKILL'd -- the one exit nothing can catch" do
    # The one exit no supervisor can catch: SIGKILL unwinds nothing, so even the
    # block form's ensure never fires. Pinned so the guarantee is not overclaimed.
    def block_form_host
      <<~RUBY
        $stdout.sync = true
        require "holder"
        Holder::Tenant.new("sleep", "#{outlives_example}").run do |handle|
          puts handle.pid
          sleep #{outlives_example}
        end
      RUBY
    end

    it "leaves the child running, because nothing gets to reap it" do
      host = spawn_ruby_host(block_form_host)
      child = live_pid_from(host.stdout)
      Process.kill("KILL", host.pid)

      expect(ProcessProbe.new(child)).to be_alive
    end
  end
end
