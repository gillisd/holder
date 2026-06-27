ENV["MT_NO_PLUGINS"] = "1" unless ENV["RM_INFO"]

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]

require "holder"
