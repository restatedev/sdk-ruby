# typed: false
# frozen_string_literal: true

require 'restate'

class Proxy < Restate::Service
  handler def call(ctx, req)
    result = ctx.generic_call(
      req['serviceName'], req['handlerName'], req['message'].pack('C*'),
      key: req['virtualObjectKey'], idempotency_key: req['idempotencyKey']
    )
    result.bytes
  end

  handler def oneWayCall(ctx, req) # rubocop:disable Naming/MethodName
    delay_seconds = req['delayMillis'] ? req['delayMillis'] / 1000.0 : nil
    ctx.generic_send(
      req['serviceName'], req['handlerName'], req['message'].pack('C*'),
      key: req['virtualObjectKey'], delay: delay_seconds, idempotency_key: req['idempotencyKey']
    )
  end

  handler def manyCalls(ctx, requests) # rubocop:disable Naming/MethodName,Metrics/AbcSize,Metrics/MethodLength
    to_await = []
    requests.each do |req|
      pr = req['proxyRequest']
      if req['oneWay']
        ctx.generic_send(pr['serviceName'], pr['handlerName'], pr['message'].pack('C*'),
                         key: pr['virtualObjectKey'], idempotency_key: pr['idempotencyKey'])
      else
        handle = ctx.generic_call_handle(pr['serviceName'], pr['handlerName'],
                                         pr['message'].pack('C*'),
                                         key: pr['virtualObjectKey'],
                                         idempotency_key: pr['idempotencyKey'])
        to_await << handle if req['awaitAtTheEnd']
      end
    end
    to_await.each { |h| ctx.resolve_handle(h) }
    nil
  end
end
