# typed: true

# ServiceDSL is extended into classes, so it has access to Module/Class methods.
# Sorbet doesn't know this when analyzing the module in isolation.

module Restate
  module ServiceDSL
    def respond_to?(name, include_all = false); end
    def _service_kind; end
    def define_method(name, &block); end
    def name; end
    def allocate; end
    def instance_method(name); end
  end
end
