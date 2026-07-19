RSpec.describe Holder::Tenant do
  describe "#pump when close_after is set and the destination raises on close" do
    let(:sink) do
      Class.new do
        def write(data) = data.bytesize

        def closed? = false

        def close = raise("close failed")
      end.new
    end

    around do |example|
      previous = Thread.report_on_exception
      Thread.report_on_exception = false
      example.run
      Thread.report_on_exception = previous
    end

    it "re-raises the close error out of the pump thread's value" do
      # DESIRED: an error raised while closing the destination should be captured
      # and returned as the thread's value -- the same contract a write error gets
      # (test_pump_captures_writer_error_as_its_value) -- so reap_pumps surfaces it
      # through pump_error rather than Thread#value re-raising it and aborting the
      # whole teardown with the owned pipes still open. thread.value should return
      # the error, not raise it.
      # CURRENT (asserted here): the close runs in the ensure, outside the pump's
      # rescue clauses, so it escapes uncaught, kills the pump thread, and
      # Thread#value re-raises it to whoever reaps the pump.
      thread = Holder::Tenant.allocate.send(:pump, StringIO.new("data"), sink, close_after: true)

      expect { thread.value }.to raise_error(RuntimeError, "close failed")
    end
  end
end
