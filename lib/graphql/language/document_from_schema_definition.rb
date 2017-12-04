# frozen_string_literal: true
module GraphQL
  module Language
    # @api private
    #
    # {GraphQL::Language::DocumentFromSchemaDefinition} is used to convert a {GraphQL::Schema} object
    # To a {GraphQL::Language::Document} AST node.
    #
    # @param context [GraphQL::Query::Context] the optional query context
    # @param warden [GraphQL::Schema::Warden] An optional schema warden to hide certain nodes
    # @param include_introspection_types [Boolean] Wether or not to print introspection types
    # @param include_introspection_types [Boolean] Wether or not to print built in types and directives
    class DocumentFromSchemaDefinition
      def initialize(
        schema, context: nil, only: nil, except: nil, include_introspection_types: false,
        include_built_in_directives: false, include_built_in_scalars: false, always_include_schema: false
      )
        @schema = schema
        @always_include_schema = always_include_schema
        @include_introspection_types = include_introspection_types
        @include_built_in_scalars = include_built_in_scalars
        @include_built_in_directives = include_built_in_directives

        @warden = GraphQL::Schema::Warden.new(
          GraphQL::Filter.new(only: only, except: except),
          schema: @schema,
          context: context,
        )
      end

      def document
        GraphQL::Language::Nodes::Document.new(
          definitions: build_definition_nodes
        )
      end

      def build_schema_node
        schema_node = GraphQL::Language::Nodes::SchemaDefinition.new

        if schema.query && warden.get_type(schema.query.name)
          schema_node.query = schema.query.name
        end

        if schema.mutation && warden.get_type(schema.mutation.name)
          schema_node.mutation = schema.mutation.name
        end

        if schema.subscription && warden.get_type(schema.subscription.name)
          schema_node.subscription = schema.subscription.name
        end

        schema_node
      end

      def build_object_type_node(object_type)
        GraphQL::Language::Nodes::ObjectTypeDefinition.new(
          name: object_type.name,
          interfaces: warden.interfaces(object_type).sort_by(&:name).map { |iface| build_type_name_node(iface) },
          fields: build_field_nodes(warden.fields(object_type)),
          description: object_type.description,
        )
      end

      def build_field_node(field)
        field_node = GraphQL::Language::Nodes::FieldDefinition.new(
          name: field.name,
          arguments: build_argument_nodes(warden.arguments(field)),
          type: build_type_name_node(field.type),
          description: field.description,
        )

        if field.deprecation_reason
          field_node.directives << GraphQL::Language::Nodes::Directive.new(
            name: GraphQL::Directive::DeprecatedDirective.name,
            arguments: [GraphQL::Language::Nodes::Argument.new(name: "reason", value: field.deprecation_reason)]
          )
        end

        field_node
      end

      def build_union_type_node(union_type)
        GraphQL::Language::Nodes::UnionTypeDefinition.new(
          name: union_type.name,
          description: union_type.description,
          types: warden.possible_types(union_type).sort_by(&:name).map { |type| build_type_name_node(type) }
        )
      end

      def build_interface_type_node(interface_type)
        GraphQL::Language::Nodes::InterfaceTypeDefinition.new(
          name: interface_type.name,
          description: interface_type.description,
          fields: build_field_nodes(warden.fields(interface_type))
        )
      end

      def build_enum_type_node(enum_type)
        GraphQL::Language::Nodes::EnumTypeDefinition.new(
          name: enum_type.name,
          values: warden.enum_values(enum_type).sort_by(&:name).map do |enum_value|
            build_enum_value_node(enum_value)
          end,
          description: enum_type.description,
        )
      end

      def build_enum_value_node(enum_value)
        enum_value_node = GraphQL::Language::Nodes::EnumValueDefinition.new(
          name: enum_value.name,
          description: enum_value.description,
        )

        if enum_value.deprecation_reason
          enum_value_node.directives << GraphQL::Language::Nodes::Directive.new(
            name: GraphQL::Directive::DeprecatedDirective.name,
            arguments: [GraphQL::Language::Nodes::Argument.new(name: "reason", value: enum_value.deprecation_reason)]
          )
        end

        enum_value_node
      end

      def build_scalar_type_node(scalar_type)
        GraphQL::Language::Nodes::ScalarTypeDefinition.new(
          name: scalar_type.name,
          description: scalar_type.description,
        )
      end

      def build_argument_node(argument)
        argument_node = GraphQL::Language::Nodes::InputValueDefinition.new(
          name: argument.name,
          description: argument.description,
          type: build_type_name_node(argument.type),
        )

        if argument.default_value?
          argument_node.default_value = build_default_value(argument.default_value, argument.type)
        end

        argument_node
      end

      def build_input_object_node(input_object)
        GraphQL::Language::Nodes::InputObjectTypeDefinition.new(
          name: input_object.name,
          fields: build_argument_nodes(warden.arguments(input_object)),
          description: input_object.description,
        )
      end

      def build_directive_node(directive)
        GraphQL::Language::Nodes::DirectiveDefinition.new(
          name: directive.name,
          arguments: build_argument_nodes(warden.arguments(directive)),
          locations: directive.locations.map(&:to_s),
          description: directive.description,
        )
      end

      def build_type_name_node(type)
        case type
        when GraphQL::ListType
          GraphQL::Language::Nodes::ListType.new(
            of_type: build_type_name_node(type.of_type)
          )
        when GraphQL::NonNullType
          GraphQL::Language::Nodes::NonNullType.new(
            of_type: build_type_name_node(type.of_type)
          )
        else
          GraphQL::Language::Nodes::TypeName.new(name: type.name)
        end
      end

      def build_default_value(default_value, type)
        if default_value.nil?
          return GraphQL::Language::Nodes::NullValue.new(name: "null")
        end

        case type
        when GraphQL::ScalarType
          default_value
        when EnumType
          GraphQL::Language::Nodes::Enum.new(name: type.coerce_isolated_result(default_value))
        when InputObjectType
          GraphQL::Language::Nodes::InputObject.new(
            arguments: default_value.to_h.map do |arg_name, arg_value|
              arg_type = type.input_fields.fetch(arg_name.to_s).type
              GraphQL::Language::Nodes::Argument.new(
                name: arg_name,
                value: build_default_value(arg_value, arg_type)
              )
            end
          )
        when NonNullType
          build_default_value(default_value, type.of_type)
        when ListType
          default_value.to_a.map { |v| build_default_value(v, type.of_type) }
        else
          raise NotImplementedError, "Unexpected default value type #{type.inspect}"
        end
      end

      def build_type_definition_node(type)
        case type
        when GraphQL::ObjectType
          build_object_type_node(type)
        when GraphQL::UnionType
          build_union_type_node(type)
        when GraphQL::InterfaceType
          build_interface_type_node(type)
        when GraphQL::ScalarType
          build_scalar_type_node(type)
        when GraphQL::EnumType
          build_enum_type_node(type)
        when GraphQL::InputObjectType
          build_input_object_node(type)
        else
          raise TypeError
        end
      end

      def build_argument_nodes(arguments)
        arguments
          .map { |arg| build_argument_node(arg) }
          .sort_by(&:name)
      end

      def build_directive_nodes(directives)
        if !include_built_in_directives
          directives = directives.reject { |directive| directive.default_directive? }
        end

        directives
          .map { |directive| build_directive_node(directive) }
          .sort_by(&:name)
      end

      def build_definition_nodes
        definitions = []
        definitions << build_schema_node if include_schema_node?
        definitions += build_directive_nodes(warden.directives)
        definitions += build_type_definition_nodes(warden.types)
        definitions
      end

      def build_type_definition_nodes(types)
        if !include_introspection_types
          types = types.reject { |type| type.introspection? }
        end

        if !include_built_in_scalars
          types = types.reject { |type| type.default_scalar? }
        end

        types
          .map { |type| build_type_definition_node(type) }
          .sort_by(&:name)
      end

      def build_field_nodes(fields)
        fields
          .map { |field| build_field_node(field) }
          .sort_by(&:name)
      end

      private

      def include_schema_node?
        always_include_schema || !schema.respects_root_name_conventions?
      end

      attr_reader :schema, :warden, :always_include_schema,
        :include_introspection_types, :include_built_in_directives, :include_built_in_scalars
    end
  end
end
