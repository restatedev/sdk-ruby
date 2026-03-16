# typed: ignore # rubocop:disable Sorbet/FalseSigil
# frozen_string_literal: true

#
# Example: Typed Handlers with dry-struct
#
# Shows how to use dry-struct for typed input/output with automatic
# JSON Schema generation. Restate publishes the schema via discovery,
# and the SDK deserializes JSON into struct instances automatically.
#
# Requires the dry-struct gem:
#   gem 'dry-struct'
#
# Features:
#   - input: / output:   — declare typed handler I/O
#   - Dry::Struct         — auto-detected, generates JSON Schema
#   - Primitive types     — String, Integer, etc. also generate schema
#   - Custom serde        — pass any object with serialize/deserialize
#
# Try it:
#   curl localhost:8080/TicketService/reserve \
#     -H 'content-type: application/json' \
#     -d '{"concert": "restate-fest", "num_tickets": 2}'
#
#   curl localhost:8080/TicketService/reserve \
#     -H 'content-type: application/json' \
#     -d '{"concert": "restate-fest", "num_tickets": 2, "seat_preference": "front"}'

require 'restate'
require 'dry-struct'

module Types
  include Dry.Types()
end

# ──────────────────────────────────────────────
# Typed request/response structs
# ──────────────────────────────────────────────

class ReservationRequest < Dry::Struct
  attribute :concert, Types::String
  attribute :num_tickets, Types::Integer
  attribute? :seat_preference, Types::String # optional attribute
end

class ReservationResponse < Dry::Struct
  attribute :reservation_id, Types::String
  attribute :concert, Types::String
  attribute :num_tickets, Types::Integer
  attribute :status, Types::String
end

# ──────────────────────────────────────────────
# Service with typed handlers
# ──────────────────────────────────────────────

class TicketService < Restate::Service
  # input: and output: accept type classes — the SDK auto-resolves
  # serde and JSON Schema from Dry::Struct definitions.
  handler :reserve, input: ReservationRequest, output: ReservationResponse
  def reserve(request)
    ctx = Restate.current_context
    # request is a ReservationRequest instance, not a raw Hash
    reservation_id = ctx.run_sync('create-reservation') do
      "res_#{request.concert}_#{rand(10_000)}"
    end

    seat = request.seat_preference || 'any'

    ctx.run_sync('assign-seats') do
      puts "Assigning #{request.num_tickets} seats (preference: #{seat}) for #{request.concert}"
    end

    # Return a ReservationResponse — serialized to JSON automatically
    ReservationResponse.new(
      reservation_id: reservation_id,
      concert: request.concert,
      num_tickets: request.num_tickets,
      status: 'confirmed'
    )
  end

  # Primitive types also generate JSON Schema for discovery
  handler :lookup, input: String, output: String
  def lookup(reservation_id)
    "status for #{reservation_id}: confirmed"
  end
end
