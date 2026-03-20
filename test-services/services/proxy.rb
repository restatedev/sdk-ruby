# typed: false
# frozen_string_literal: true

require 'restate'

class Proxy < Restate::Service
  handler def call(req)
    result = Restate.generic_call(
      req['serviceName'], req['handlerName'], req['message'].pack('C*'),
      key: req['virtualObjectKey'], idempotency_key: req['idempotencyKey']
    ).await
    result.bytes
  end

  handler def oneWayCall(req) # rubocop:disable Naming/MethodName
    delay_seconds = req['delayMillis'] ? req['delayMillis'] / 1000.0 : nil
    handle = Restate.generic_send(
      req['serviceName'], req['handlerName'], req['message'].pack('C*'),
      key: req['virtualObjectKey'], delay: delay_seconds, idempotency_key: req['idempotencyKey']
    )
    handle.invocation_id
  end

  handler def manyCalls(requests) # rubocop:disable Naming/MethodName,Metrics/AbcSize,Metrics/MethodLength
    to_await = []
    requests.each do |req|
      pr = req['proxyRequest']
      if req['oneWay']
        Restate.generic_send(pr['serviceName'], pr['handlerName'], pr['message'].pack('C*'),
                             key: pr['virtualObjectKey'], idempotency_key: pr['idempotencyKey'])
      else
        future = Restate.generic_call(pr['serviceName'], pr['handlerName'],
                                      pr['message'].pack('C*'),
                                      key: pr['virtualObjectKey'],
                                      idempotency_key: pr['idempotencyKey'])
        to_await << future if req['awaitAtTheEnd']
      end
    end
    to_await.each(&:await)
    nil
  end
end
