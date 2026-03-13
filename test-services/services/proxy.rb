# typed: false
# frozen_string_literal: true

require 'restate'

PROXY = Restate.service('Proxy')

PROXY.handler('call') do |ctx, req|
  result = ctx.generic_call(
    req['serviceName'], req['handlerName'], req['message'].pack('C*'),
    key: req['virtualObjectKey'], idempotency_key: req['idempotencyKey']
  )
  result.bytes
end

PROXY.handler('oneWayCall') do |ctx, req|
  delay_seconds = req['delayMillis'] ? req['delayMillis'] / 1000.0 : nil
  ctx.generic_send(
    req['serviceName'], req['handlerName'], req['message'].pack('C*'),
    key: req['virtualObjectKey'], delay: delay_seconds, idempotency_key: req['idempotencyKey']
  )
end

PROXY.handler('manyCalls') do |ctx, requests|
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
