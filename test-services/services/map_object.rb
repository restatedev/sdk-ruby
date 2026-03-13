# frozen_string_literal: true

require "restate"

MAP_OBJECT = Restate.virtual_object("MapObject")

MAP_OBJECT.handler("set") do |ctx, entry|
  ctx.set(entry["key"], entry["value"])
  nil
end

MAP_OBJECT.handler("get") do |ctx, key|
  ctx.get(key) || ""
end

MAP_OBJECT.handler("clearAll") do |ctx|
  entries = []
  ctx.state_keys.each do |key|
    value = ctx.get(key)
    entries << { "key" => key, "value" => value }
    ctx.clear(key)
  end
  entries
end
