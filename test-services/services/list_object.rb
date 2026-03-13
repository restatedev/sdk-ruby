# frozen_string_literal: true

require "restate"

LIST_OBJECT = Restate.virtual_object("ListObject")

LIST_OBJECT.handler("append") do |ctx, value|
  list = ctx.get("list") || []
  ctx.set("list", list + [value])
  nil
end

LIST_OBJECT.handler("get") do |ctx|
  ctx.get("list") || []
end

LIST_OBJECT.handler("clear") do |ctx|
  result = ctx.get("list") || []
  ctx.clear("list")
  result
end
