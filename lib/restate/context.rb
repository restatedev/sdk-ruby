# typed: true
# frozen_string_literal: true

module Restate
  # Request metadata available to handlers via +ctx.request+.
  #
  # @!attribute [r] id
  #   @return [String] the invocation ID
  # @!attribute [r] headers
  #   @return [Hash{String => String}] request headers
  # @!attribute [r] body
  #   @return [String] raw input bytes
  Request = Struct.new(:id, :headers, :body, keyword_init: true)
end
