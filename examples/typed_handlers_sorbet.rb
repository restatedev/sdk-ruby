# typed: true
# frozen_string_literal: true

#
# Example: Typed Handlers with T::Struct (Sorbet)
#
# Shows how to use Sorbet's T::Struct for typed input/output with automatic
# JSON Schema generation. This is the Sorbet-native alternative to dry-struct,
# giving you full IDE support and type checking.
#
# Features:
#   - input: / output:   — declare typed handler I/O
#   - T::Struct           — auto-detected, generates JSON Schema
#   - T.nilable           — optional fields
#   - Primitive types     — String, Integer, etc. also generate schema
#
# Try it:
#   curl localhost:8080/EventService/register \
#     -H 'content-type: application/json' \
#     -d '{"event_name": "restate-conf", "attendee": "Alice", "num_guests": 2}'
#
#   curl localhost:8080/EventService/register \
#     -H 'content-type: application/json' \
#     -d '{"event_name": "restate-conf", "attendee": "Bob", "num_guests": 1, "note": "vegetarian"}'

require 'restate'

# ──────────────────────────────────────────────
# Typed request/response structs
# ──────────────────────────────────────────────

class RegistrationRequest < T::Struct
  const :event_name, String
  const :attendee, String
  const :num_guests, Integer
  const :note, T.nilable(String)
end

class RegistrationResponse < T::Struct
  const :registration_id, String
  const :event_name, String
  const :attendee, String
  const :num_guests, Integer
  const :status, String
end

# ──────────────────────────────────────────────
# Service with typed handlers
# ──────────────────────────────────────────────

class EventService < Restate::Service
  # input: and output: accept type classes — the SDK auto-resolves
  # serde and JSON Schema from T::Struct definitions.
  handler :register, input: RegistrationRequest, output: RegistrationResponse
  # @param request [RegistrationRequest]
  # @return [RegistrationResponse]
  def register(request)
    # request is a RegistrationRequest instance, not a raw Hash
    registration_id = Restate.run_sync('create-registration') do
      "reg_#{request.event_name}_#{rand(10_000)}"
    end

    note = request.note || 'none'

    Restate.run_sync('confirm-seats') do
      puts "Confirming #{request.num_guests} seats for #{request.attendee} at #{request.event_name} (note: #{note})"
    end

    # Return a RegistrationResponse — serialized to JSON automatically
    RegistrationResponse.new(
      registration_id: registration_id,
      event_name: request.event_name,
      attendee: request.attendee,
      num_guests: request.num_guests,
      status: 'confirmed'
    )
  end

  # Primitive types also generate JSON Schema for discovery
  handler :lookup, input: String, output: String
  # @param registration_id [String]
  # @return [String]
  def lookup(registration_id)
    "status for #{registration_id}: confirmed"
  end
end
