# typed: false
# frozen_string_literal: true

require 'restate'

AWAKEABLE_HOLDER = Restate.virtual_object('AwakeableHolder')

AWAKEABLE_HOLDER.handler('hold') do |ctx, id|
  ctx.set('id', id)
  nil
end

AWAKEABLE_HOLDER.handler('hasAwakeable') do |ctx|
  result = ctx.get('id')
  !result.nil?
end

AWAKEABLE_HOLDER.handler('unlock') do |ctx, payload|
  id = ctx.get('id')
  raise Restate::TerminalError, 'No awakeable is registered' if id.nil?

  ctx.resolve_awakeable(id, payload)
  nil
end
