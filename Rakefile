# frozen_string_literal: true

require 'rake/extensiontask'
require 'rspec/core/rake_task'

Rake::ExtensionTask.new('restate_internal') do |ext|
  ext.lib_dir = 'lib/restate'
  ext.source_pattern = '*.{rs,toml}'
  ext.cross_compile = true
end

RSpec::Core::RakeTask.new(:spec)

task default: %i[compile spec]
