require "bundler/gem_tasks"

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

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
