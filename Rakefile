# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec) { |t| t.exclude_pattern = "spec/e2e/**/*_spec.rb" }
RSpec::Core::RakeTask.new(:e2e) { |t| t.pattern = "spec/e2e/**/*_spec.rb" }
RuboCop::RakeTask.new
task default: %i[rubocop spec]
