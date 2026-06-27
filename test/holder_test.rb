require "test_helper"

class HolderTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil Holder::VERSION
  end
end
