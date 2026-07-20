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

require_relative "support/example_cleanup"
require_relative "support/handle_helpers"
require_relative "support/io_helpers"
require_relative "support/process_helpers"
require_relative "support/unsignalable_command"
require_relative "support/watchdog"

RSpec.configure do |config|
  config.include ExampleCleanup
  config.include HandleHelpers
  config.include IoHelpers
  config.include ProcessHelpers

  # The directory is the tier: spec/unit is the fast floor, spec/integration
  # stages real children. Watchdog turns that into each example's time budget.
  config.define_derived_metadata(file_path: %r{/spec/unit/}) { |metadata| metadata[:tier] = :unit }
  config.define_derived_metadata(file_path: %r{/spec/integration/}) { |metadata| metadata[:tier] = :integration }

  # A nil exception class is deliberate: Timeout then raises its ExitException,
  # which is not a StandardError, so an example wedged inside a `rescue` cannot
  # swallow its own watchdog.
  config.around do |example|
    budget = Watchdog.budget(example.metadata)
    Timeout.timeout(budget, nil, "example exceeded its #{example.metadata[:tier]} budget of #{budget}s") do
      example.run
    end
  end

  config.after { @cleanup&.run }

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = ".rspec_status"
end
