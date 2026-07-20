RSpec.describe Holder::Handle do
  describe "#terminate when a pump failed" do
    it "closes the pipes it owns" do
      reader, writer = make_pipe
      handle = handle_with_failed_pump(owned_ios: [reader, writer])

      handle.terminate(grace: 0.5)

      expect([reader, writer]).to all(be_closed)
    end

    it "surfaces the pump's error" do
      handle = handle_with_failed_pump(owned_ios: make_pipe)

      handle.terminate(grace: 0.5)

      expect(handle.pump_error).to be_a(RuntimeError)
    end
  end

  describe "#terminate when both the feed and drain pumps failed" do
    it "surfaces the drain pump's error" do
      # The drain pump outranks the feed pump because a failed drain lost output
      # the caller redirected, while a failed feed merely starved a child that is
      # already gone.
      feed = Thread.new { RuntimeError.new("feed broke") }
      drain = Thread.new { RuntimeError.new("drain broke") }
      handle = handle_with_pumps(pump_threads: [feed, drain], drain_pump: drain)

      handle.terminate(grace: 0.5)

      expect(handle.pump_error.message).to eq("drain broke")
    end
  end
end
