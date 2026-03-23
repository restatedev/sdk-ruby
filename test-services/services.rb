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
require_relative 'services/interpreter'

ALL_SERVICES = [
  Counter, ListObject, MapObject, Failing, NonDeterministic,
  TestUtilsService, Proxy, AwakeableHolder, CancelTestRunner,
  CancelTestBlockingService, KillTestRunner, KillTestSingleton,
  BlockAndWaitWorkflow, VirtualObjectCommandInterpreter,
  ServiceInterpreterHelper, ObjectInterpreterL0, ObjectInterpreterL1, ObjectInterpreterL2
].freeze

def services_named(names)
  ALL_SERVICES.select { |svc| names.include?(svc.service_name) }
end

def test_services
  names = ENV.fetch('SERVICES', nil)
  if names
    services_named(names.split(','))
  else
    ALL_SERVICES
  end
end
