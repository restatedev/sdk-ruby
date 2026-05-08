# typed: false
# frozen_string_literal: true

module Restate
  # Rails integration for the Restate SDK. Automatically loads the
  # introspection module which provides Arel-based query support for
  # Restate's SQL introspection API (powered by DataFusion).
  #
  # When Rails is present, +Restate::Sys+ table constants become available
  # for building type-safe, composable queries against system tables like
  # +sys_invocation+, +sys_journal+, and +state+.
  class Railtie < Rails::Railtie
    initializer 'restate.introspection' do
      require_relative 'introspection'
    end
  end
end
