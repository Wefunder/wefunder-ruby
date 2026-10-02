# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
# The live group is opt-in (spec_helper filters :e2e unless WEFUNDER_E2E=1). The flag must be set
# BEFORE RSpec runs, so it is a prerequisite task, not an action appended after RSpec's own.
task(:e2e_env) { ENV["WEFUNDER_E2E"] = "1" }
RSpec::Core::RakeTask.new(e2e: :e2e_env) { |t| t.pattern = "spec/e2e/**/*_spec.rb" }
RuboCop::RakeTask.new
task default: %i[rubocop spec]
