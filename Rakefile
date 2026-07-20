require "bundler/gem_tasks"

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

namespace :spec do
  desc "Run the fast tier only -- pure logic, no child processes"
  RSpec::Core::RakeTask.new(:unit) { |task| task.pattern = "spec/unit/**/*_spec.rb" }

  desc "Run the integration tier only -- real children, timing budgets"
  RSpec::Core::RakeTask.new(:integration) { |task| task.pattern = "spec/integration/**/*_spec.rb" }
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

require "gempilot/version_task"
Gempilot::VersionTask.new

namespace :zeitwerk do
  desc "Verify all files follow Zeitwerk naming conventions"
  task :validate do
    ruby "-e", <<~RUBY
      require 'holder'
      Holder::LOADER.eager_load(force: true)
      puts 'Zeitwerk: All files loaded successfully.'
    RUBY
  end
end

task default: [:spec, :rubocop]
