# typed: true
# frozen_string_literal: true

module Restate
  # Request metadata available to handlers.
  Request = Struct.new(:id, :headers, :body, keyword_init: true)
end
