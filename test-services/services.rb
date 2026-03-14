# typed: false
# frozen_string_literal: true

require_relative 'services/counter'
require_relative 'services/list_object'
require_relative 'services/map_object'
require_relative 'services/failing'
require_relative 'services/non_determinism'
require_relative 'services/test_utils'
require_relative 'services/proxy'
require_relative 'services/awakeable_holder'
require_relative 'services/cancel_test'
require_relative 'services/kill_test'
require_relative 'services/block_and_wait_workflow'
require_relative 'services/virtual_object_command_interpreter'

ALL_SERVICES = {
  'Counter' => COUNTER,
  'ListObject' => LIST_OBJECT,
  'MapObject' => MAP_OBJECT,
  'Failing' => FAILING,
  'NonDeterministic' => NON_DETERMINISTIC,
  'TestUtilsService' => TEST_UTILS,
  'Proxy' => PROXY,
  'AwakeableHolder' => AWAKEABLE_HOLDER,
  'CancelTestRunner' => CANCEL_TEST_RUNNER,
  'CancelTestBlockingService' => CANCEL_TEST_BLOCKING_SERVICE,
  'KillTestRunner' => KILL_TEST_RUNNER,
  'KillTestSingleton' => KILL_TEST_SINGLETON,
  'BlockAndWaitWorkflow' => BLOCK_AND_WAIT_WORKFLOW,
  'VirtualObjectCommandInterpreter' => VIRTUAL_OBJECT_COMMAND_INTERPRETER
}.freeze

def services_named(names)
  names.filter_map { |name| ALL_SERVICES[name] }
end

def test_services
  names = ENV.fetch('SERVICES', nil)
  if names
    services_named(names.split(','))
  else
    ALL_SERVICES.values
  end
end
