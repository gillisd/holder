RSpec.describe Holder::Handle do
  describe "#wait when the redirected out: sink can never accept the child's output" do
    let(:reader_and_writer) { make_pipe }
    let(:writer) { reader_and_writer.last }

    before { fill_pipe(writer) }

    it "returns instead of blocking forever on the wedged drain" do
      handle = spawn_process("sh", "-c", "echo blocked", out: writer)

      expect { Timeout.timeout(3) { handle.wait } }.not_to raise_error
    end
  end
end
