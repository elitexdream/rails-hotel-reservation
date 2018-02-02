# frozen_string_literal: true

module Platform
  module Scalars
    DateTime = GraphQL::ScalarType.define do
      name "DateTime"
      description "An ISO-8601 encoded UTC date string."

      coerce_input -> (value, context) do
        begin
          Time.iso8601(value)
        rescue ArgumentError, ::TypeError
        end
      end

      coerce_result -> (value, context) do
        return nil unless value
        value.utc.iso8601
      end
    end
  end
end
