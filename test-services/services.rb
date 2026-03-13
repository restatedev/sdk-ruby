# frozen_string_literal: true

require_relative "services/counter"
require_relative "services/list_object"
require_relative "services/map_object"
require_relative "services/failing"
require_relative "services/non_determinism"
require_relative "services/test_utils"

ALL_SERVICES = {
  "Counter" => COUNTER,
  "ListObject" => LIST_OBJECT,
  "MapObject" => MAP_OBJECT,
  "Failing" => FAILING,
  "NonDeterministic" => NON_DETERMINISTIC,
  "TestUtilsService" => TEST_UTILS
}.freeze

def services_named(names)
  names.map { |name| ALL_SERVICES.fetch(name) }
end

def test_services
  names = ENV.fetch("SERVICES", nil)
  if names
    services_named(names.split(","))
  else
    ALL_SERVICES.values
  end
end
