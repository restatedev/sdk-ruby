# frozen_string_literal: true

module Restate
  # Proxy for fluent durable calls: +Service.call.handler(arg)+
  #
  # Returned by the +.call+ class method on service classes. Uses +method_missing+
  # to forward handler invocations to the current Restate context.
  #
  # @example
  #   # Instead of: ctx.service_call(Greeter, :greet, "World")
  #   Greeter.call.greet("World")
  #
  #   # Instead of: ctx.object_call(Counter, :add, "key", 5)
  #   Counter.call("key").add(5)
  #
  # @!visibility private
  class ServiceCallProxy
    def initialize(service_class, key: nil, call_method: :service_call)
      @service_class = service_class
      @key = key
      @call_method = call_method
    end

    def method_missing(handler_name, arg = nil, **opts)
      ctx = Restate.fetch_context!
      if @key
        ctx.public_send(@call_method, @service_class, handler_name, @key, arg, **opts)
      else
        ctx.public_send(@call_method, @service_class, handler_name, arg, **opts)
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      (@service_class.respond_to?(:handlers) && @service_class.handlers.key?(method_name.to_s)) || super
    end
  end

  # Proxy for fluent fire-and-forget sends: +Service.send!.handler(arg)+
  #
  # Returned by the +.send!+ class method on service classes.
  #
  # @example
  #   # Instead of: ctx.service_send(Greeter, :greet, "World")
  #   Greeter.send!.greet("World")
  #
  #   # Instead of: ctx.object_send(Counter, :add, "key", 5, delay: 60)
  #   Counter.send!("key", delay: 60).add(5)
  #
  # @!visibility private
  class ServiceSendProxy
    def initialize(service_class, key: nil, send_method: :service_send, delay: nil)
      @service_class = service_class
      @key = key
      @send_method = send_method
      @delay = delay
    end

    def method_missing(handler_name, arg = nil, **opts)
      ctx = Restate.fetch_context!
      opts[:delay] = @delay if @delay
      if @key
        ctx.public_send(@send_method, @service_class, handler_name, @key, arg, **opts)
      else
        ctx.public_send(@send_method, @service_class, handler_name, arg, **opts)
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      (@service_class.respond_to?(:handlers) && @service_class.handlers.key?(method_name.to_s)) || super
    end
  end
end
