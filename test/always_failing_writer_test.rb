require "test_helper"

class AlwaysFailingWriterTest < Minitest::Test
  def test_write_raises_with_a_disk_full_message
    error = assert_raises(RuntimeError) { AlwaysFailingWriter.new.write("data") }

    assert_equal "disk full", error.message
  end

  def test_write_raises_regardless_of_arguments
    writer = AlwaysFailingWriter.new

    assert_raises(RuntimeError) { writer.write }
    assert_raises(RuntimeError) { writer.write("a", "b", "c") }
  end
end
