# frozen_string_literal: true

#
# Example: Concurrency Limit (scoped calls + flow-control limit keys)
#
# Shows how to route service-to-service calls within a *scope* so that Restate
# can enforce concurrency / rate-limit rules per scope. A common use case is
# wrapping a third-party API and rate-limiting calls per user-provided API key,
# so you never exceed the third-party quota.
#
# NOTE: This API is in preview and is not enabled by default. On restate-server
# 1.7 it requires the experimental protocol v7 + vqueues features:
#   RESTATE_EXPERIMENTAL_ENABLE_PROTOCOL_V7=true
#   RESTATE_EXPERIMENTAL_ENABLE_VQUEUES=true
# See https://docs.restate.dev/services/flow-control
#
# Features:
#   - Service.call(scope:, limit_key:)     — fluent call routed within a scope
#   - limit_key:                           — hierarchical concurrency limit key
#
# Try it:
#   curl localhost:8080/OrderFulfillment/process_order \
#     -H 'content-type: application/json' \
#     -d '{"orderId": "order-1", "amazonApiKey": "amz-api-key-123"}'

require 'restate'

# --- Amazon Merchant Service: a third-party API wrapper ---
class AmazonMerchantService < Restate::Service
  handler def checkout(req)
    # In a real app, this would call the Amazon Merchant API
    # using the user-provided API key from the scope.
    { 'confirmationId' => "conf-#{req['orderId']}" }
  end
end

# --- Order Fulfillment: uses scoped calls to rate-limit per API key ---
class OrderFulfillment < Restate::Service
  # Process an order by calling AmazonMerchantService within a scope keyed by
  # the user's Amazon API key.
  #
  # The scope + configured rate limit rules ensure that calls sharing the same
  # API key are rate-limited (e.g. 10 requests every 2 hours), preventing us
  # from exceeding the third-party API quota.
  #
  # Rate limit rules are configured externally in Restate:
  #
  #   # Default rule: on any scope, rate limit AmazonMerchantService to 10 req / 2h
  #   {
  #     "scope": { "any": true },
  #     "match": { "service": "AmazonMerchantService" },
  #     "limit": {
  #       "rateLimit": { "count": 10, "interval": { "hours": 2 } }
  #     }
  #   }
  #
  #   # Override for a specific API key: increase limit to 100 req / 2h
  #   {
  #     "scope": { "equals": "amz-api-key-123" },
  #     "match": { "service": "AmazonMerchantService" },
  #     "limit": {
  #       "rateLimit": { "count": 100, "interval": { "hours": 2 } }
  #     }
  #   }
  handler def process_order(req)
    # Scope the call by the user's Amazon API key.
    # Restate enforces the rate limit rules configured above.
    response = AmazonMerchantService.call(scope: req['amazonApiKey']).checkout(
      { 'orderId' => req['orderId'], 'productId' => 'product-42', 'quantity' => 1 }
    ).await

    "Order #{req['orderId']} confirmed: #{response['confirmationId']}"
  end
end
