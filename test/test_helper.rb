unless ENV["RM_INFO"]
  require "minitest/reporters"
  Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]
end
require "minitest/autorun"
require "holder"
