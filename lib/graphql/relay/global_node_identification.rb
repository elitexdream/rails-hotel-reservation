require 'singleton'
module GraphQL
  module Relay
    # This object provides helpers for working with global IDs.
    # It's assumed you'll only have 1!
    # GlobalIdField depends on that, since it calls class methods
    # which delegate to the singleton instance.
    class GlobalNodeIdentification
      # Just to encode data in the id, use something that won't conflict
      ID_AND_TYPE_SEPARATOR = "---"

      include GraphQL::DefinitionHelpers::DefinedByConfig
      defined_by_config :object_from_id_proc, :type_from_object_proc
      attr_accessor :object_from_id_proc, :type_from_object_proc

      class << self
        attr_accessor :instance
        def new(*args, &block)
          @instance = super
        end

        def from_global_id(id)
          instance.from_global_id(id)
        end

        def to_global_id(type_name, id)
          instance.to_global_id(type_name, id)
        end
      end

      # Returns `NodeInterface`, which all Relay types must implement
      def interface
        @interface ||= begin
          ident = self
          GraphQL::InterfaceType.define do
            name "Node"
            field :id, !types.ID
            resolve_type -> (obj) {
              ident.type_from_object(obj)
            }
          end
        end
      end

      # Returns a field for finding objects from a global ID, which Relay needs
      def field
        ident = self
        GraphQL::Field.define do
          type(ident.interface)
          argument :id, !types.ID
          resolve -> (obj, args, ctx) {
            ident.object_from_id(args[:id])
          }
        end
      end

      # Create a global ID for type-name & ID
      # (This is an opaque transform)
      def to_global_id(type_name, id)
        if type_name.include?(ID_AND_TYPE_SEPARATOR) || id.include?(ID_AND_TYPE_SEPARATOR)
          raise "to_global_id(#{type_name}, #{id}) contains reserved characters `#{ID_AND_TYPE_SEPARATOR}`"
        end
        Base64.strict_encode64([type_name, id].join(ID_AND_TYPE_SEPARATOR))
      end

      # Get type-name & ID from global ID
      # (This reverts the opaque transform)
      def from_global_id(global_id)
        Base64.decode64(global_id).split(ID_AND_TYPE_SEPARATOR)
      end

      # Use the provided config to
      # get a type for a given object
      def type_from_object(object)
        type_result = @type_from_object_proc.call(object)
        if !type_result.is_a?(GraphQL::BaseType)
          type_str = "#{type_result} (#{type_result.class.name})"
          raise "type_from_object(#{object}) returned #{type_str}, but it should return a GraphQL type"
        else
          type_result
        end
      end

      # Use the provided config to
      # get an object from a UUID
      def object_from_id(id)
        @object_from_id_proc.call(id)
      end
    end
  end
end
