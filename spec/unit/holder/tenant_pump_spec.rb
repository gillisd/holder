RSpec.describe Holder::Tenant do
  describe "#pump when the destination raises on write" do
    it "captures the write error as the pump's value instead of killing the thread" do
      thread = Holder::Tenant.allocate.send(:pump, StringIO.new("data"), AlwaysFailingWriter.new)

      expect(thread.value).to be_a(RuntimeError)
    end
  end
end
