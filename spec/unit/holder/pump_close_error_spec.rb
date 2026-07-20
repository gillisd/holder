RSpec.describe Holder::Tenant do
  describe "#pump when close_after is set and the destination raises on close" do
    let(:sink) do
      Class.new do
        def write(data) = data.bytesize

        def closed? = false

        def close = raise("close failed")
      end.new
    end

    it "captures the close error as the pump's value instead of killing the thread" do
      # An error raised while closing the destination gets the same contract a
      # write error does (test_pump_captures_writer_error_as_its_value): captured
      # and returned as the thread's value, so reap_pumps surfaces it through
      # pump_error rather than Thread#value re-raising it and aborting the whole
      # teardown with the owned pipes still open.
      thread = Holder::Tenant.allocate.send(:pump, StringIO.new("data"), sink, close_after: true)

      expect(thread.value).to be_a(RuntimeError).and have_attributes(message: "close failed")
    end
  end
end
