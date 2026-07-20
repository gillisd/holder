require "holder"
require "open3"
require "stringio"
require "timeout"

# Reuse the minitest suite's support classes (Cleanup, ProcessProbe, Clock,
# AlwaysFailingWriter) -- one per file under test/support -- so the specs and the
# tests share one set of process-wrangling primitives. Eager-load up front so a
# missing or misnamed support file fails at boot, not partway through a run.
require "zeitwerk"
support_loader = Zeitwerk::Loader.new
support_loader.push_dir(File.expand_path("../test/support", __dir__))
support_loader.setup
support_loader.eager_load

require_relative "support/process_helpers"
require_relative "support/unsignalable_command"

RSpec.configure do |config|
  config.include ProcessHelpers

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = ".rspec_status"

  config.after { @cleanup&.run }
end
