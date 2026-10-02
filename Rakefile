# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RSpec::Core::RakeTask.new(:e2e) { |t| t.pattern = "spec/e2e/**/*_spec.rb" }
task(:e2e) { ENV["WEFUNDER_E2E"] = "1" } # opt-in gate for the live group (see spec_helper)
RuboCop::RakeTask.new
task default: %i[rubocop spec]
