module GraphQL
  module Language
    # Emitted by the lexer and passed to the parser.
    # Contains type, value and position data.
    class Token
      # @return [Symbol] The kind of token this is
      attr_reader :name

      def initialize(value:, name:, line:, col:)
        @name = name
        @value = value
        @line = line
        @col = col
      end

      def to_s; @value; end
      def to_i; @value.to_i; end
      def to_f; @value.to_f; end

      def line_and_column
        [@line, @col]
      end
    end
  end
end
