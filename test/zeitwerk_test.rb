require "test_helper"

class ZeitwerkTest < Minitest::Test
  def test_eager_loading
    Holder::LOADER.eager_load(force: true)

    assert_kind_of Zeitwerk::Loader, Holder::LOADER
  end
end
