unless ENV["RM_INFO"]
  require "minitest/reporters"
  Minitest::Reporters.use! [Minitest::Reporters::DefaultReporter.new(color: true)]
end
require "minitest/autorun"
require "holder"

# Autoload the test support classes (Clock, ProcessProbe, Cleanup,
# AlwaysFailingWriter) -- one per file under test/support, no explicit requires.
# Eager-load up front: the suite runs threaded (parallelize_me!), so we resolve
# every constant before any worker thread starts rather than autoloading mid-run.
require "zeitwerk"
support_loader = Zeitwerk::Loader.new
support_loader.push_dir("#{__dir__}/support")
support_loader.setup
support_loader.eager_load
