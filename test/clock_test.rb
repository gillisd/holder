require "test_helper"

class ClockTest < Minitest::Test
  def test_monotonic_returns_a_float
    assert_kind_of Float, Clock.monotonic
  end

  def test_monotonic_never_goes_backwards
    first = Clock.monotonic

    assert_operator Clock.monotonic, :>=, first
  end
end
