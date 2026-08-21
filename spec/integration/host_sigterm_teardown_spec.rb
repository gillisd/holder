RSpec.describe "reaping a holder's child when its host process is sent SIGTERM" do
  # A real host: a ruby program that supervises a child with the block form and
  # then idles inside the block, holding the child, until we signal it. Ruby
  # unwinds `ensure` on an untrapped SIGTERM, so the block's `handle.terminate`
  # runs on the way out and the child goes with the host -- the guarantee this
  # example pins. It prints the child's pid first, so the example probes the
  # child on its own rather than through the dying host.
  let(:block_form_host) do
    <<~RUBY
      $stdout.sync = true
      require "holder"
      Holder::Tenant.new("sleep", "#{outlives_example}").run do |handle|
        puts handle.pid
        sleep #{outlives_example}
      end
    RUBY
  end

  it "kills the child the host was supervising" do
    host = spawn_ruby_host(block_form_host)
    child = live_pid_from(host.stdout)
    Process.kill("TERM", host.pid)

    expect(ProcessProbe.new(child)).to be_dead_within(2)
  end
end
