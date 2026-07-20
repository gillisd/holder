RSpec.describe "a no-block holder's child when its host process exits" do
  # A real host: a ruby program that supervises a child with the NO-BLOCK form
  # and then simply reaches EOF. The no-block form registers no at_exit, so the
  # host exiting tears nothing down and the child outlives it -- the counterpart
  # to the block form's ensure (see host_sigterm_teardown_spec). It prints the
  # child's pid first, so the example can probe the child once the host is gone.
  let(:no_block_host) do
    <<~RUBY
      $stdout.sync = true
      require "holder"
      handle = Holder::Tenant.new("sleep", "#{outlives_example}").run
      puts handle.pid
    RUBY
  end

  it "outlives the host that never tore it down" do
    host = spawn_ruby_host(no_block_host)
    child = live_pid_from(host.stdout)
    host.wait

    expect(ProcessProbe.new(child)).to be_alive
  end
end
