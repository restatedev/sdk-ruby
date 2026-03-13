# typed: false
# frozen_string_literal: true

require 'restate'

COUNTER = Restate.virtual_object('Counter')

COUNTER.handler('reset') do |ctx|
  ctx.clear('counter')
  nil
end

COUNTER.handler('get') do |ctx|
  ctx.get('counter') || 0
end

COUNTER.handler('add') do |ctx, addend|
  old_value = ctx.get('counter') || 0
  new_value = old_value + addend
  ctx.set('counter', new_value)
  { 'oldValue' => old_value, 'newValue' => new_value }
end

COUNTER.handler('addThenFail') do |ctx, addend|
  old_value = ctx.get('counter') || 0
  new_value = old_value + addend
  ctx.set('counter', new_value)
  raise Restate::TerminalError, ctx.key
end
