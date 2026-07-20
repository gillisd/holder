RSpec.describe Holder::Tenant do
  describe "#run given an in: redirect" do
    it "feeds the child from the source until EOF" do
      out = open_tmp("w")
      spawn_process("sort", in: input_io("b\na\nc\n"), out: out).wait
      out.close

      expect(File.read(out.path).chomp).to eq("a\nb\nc")
    end

    it "still pipes the child's stdout back when no out: or err: is given" do
      output = Holder::Tenant.new("cat", in: input_io("solo\n")).run { |handle| handle.stdout.read }

      expect(output.chomp).to eq("solo")
    end

    it "routes the child's stderr to the err: file while reading from the source" do
      err = open_tmp("w")
      spawn_process("sh", "-c", "cat 1>&2", in: input_io("toerr\n"), err: err).wait
      err.close

      expect(File.read(err.path).chomp).to eq("toerr")
    end
  end

  describe "#run given an out: redirect" do
    it "writes the child's stdout to the file" do
      out = open_tmp("w")
      spawn_process("sh", "-c", "echo to_file", out: out).wait
      out.close

      expect(File.read(out.path).chomp).to eq("to_file")
    end
  end

  describe "#run given an err: redirect" do
    it "writes the child's stderr to the file" do
      err = open_tmp("w")
      spawn_process("sh", "-c", "echo oops 1>&2", err: err).wait
      err.close

      expect(File.read(err.path).chomp).to eq("oops")
    end
  end

  describe "#run given a chdir: spawn kwarg" do
    it "starts the child in that directory" do
      dir = tmpdir
      out = open_tmp("w")
      spawn_process("sh", "-c", "pwd", out: out, chdir: dir).wait
      out.close

      # Compare canonical paths: macOS resolves /tmp through the /private symlink,
      # so the child reports /private/tmp/... while dir is /tmp/... -- same directory.
      expect(File.realpath(File.read(out.path).strip)).to eq(File.realpath(dir))
    end
  end
end
