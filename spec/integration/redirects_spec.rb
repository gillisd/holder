RSpec.describe "redirecting a child's standard streams and forwarding spawn kwargs" do
  let(:sink) { open_tmp("w") }

  def text_captured_in(file)
    file.close
    File.read(file.path).chomp
  end

  describe "an in: redirect" do
    it "feeds the child from the source until EOF" do
      spawn_process("sort", in: input_io("b\na\nc\n"), out: sink).wait

      expect(text_captured_in(sink)).to eq("a\nb\nc")
    end

    it "still pipes the child's stdout back when no out: or err: is given" do
      output = Holder::Tenant.new("cat", in: input_io("solo\n")).run { |handle| handle.stdout.read }

      expect(output.chomp).to eq("solo")
    end

    it "routes the child's stderr to the err: file while reading from the source" do
      spawn_process("sh", "-c", "cat 1>&2", in: input_io("toerr\n"), err: sink).wait

      expect(text_captured_in(sink)).to eq("toerr")
    end
  end

  describe "an out: redirect" do
    it "writes the child's stdout to the file" do
      spawn_process("sh", "-c", "echo to_file", out: sink).wait

      expect(text_captured_in(sink)).to eq("to_file")
    end
  end

  describe "an err: redirect" do
    it "writes the child's stderr to the file" do
      spawn_process("sh", "-c", "echo oops 1>&2", err: sink).wait

      expect(text_captured_in(sink)).to eq("oops")
    end
  end

  describe "a chdir: spawn kwarg" do
    let(:working_directory) { tmpdir }

    # Compare canonical paths: macOS resolves /tmp through the /private symlink,
    # so the child reports /private/tmp/... while working_directory is /tmp/... --
    # same directory.
    it "starts the child in that directory" do
      spawn_process("sh", "-c", "pwd", out: sink, chdir: working_directory).wait

      expect(File.realpath(text_captured_in(sink))).to eq(File.realpath(working_directory))
    end
  end
end
