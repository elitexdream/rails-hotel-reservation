# frozen_string_literal: true
module GraphQL
  class Schema
    class IntrospectionSystem
      attr_reader :types

      def initialize(schema)
        @schema = schema
        @class_based = !!@schema.is_a?(Class)
        @built_in_namespace = GraphQL::Introspection
        @custom_namespace = if @class_based
          schema.introspection || @built_in_namespace
        else
          schema.introspection_namespace || @built_in_namespace
        end

        type_defns = [
          load_constant(:SchemaType),
          load_constant(:TypeType),
          load_constant(:FieldType),
          load_constant(:DirectiveType),
          load_constant(:EnumValueType),
          load_constant(:InputValueType),
          load_constant(:TypeKindEnum),
          load_constant(:DirectiveLocationEnum)
        ]
        @types = {}
        type_defns.each do |t|
          @types[t.graphql_name] = t
        end

        @entry_point_fields =
          if schema.disable_introspection_entry_points?
            {}
          else
            get_fields_from_class(class_sym: :EntryPoints)
          end
        @dynamic_fields = get_fields_from_class(class_sym: :DynamicFields)
      end

      def entry_points
        @entry_point_fields.values
      end

      def entry_point(name:)
        @entry_point_fields[name]
      end

      def dynamic_fields
        @dynamic_fields.values
      end

      def dynamic_field(name:)
        @dynamic_fields[name]
      end

      # The introspection system is prepared with a bunch of LateBoundTypes.
      # Replace those with the objects that they refer to, since LateBoundTypes
      # aren't handled at runtime.
      #
      # @api private
      # @return void
      def resolve_late_bindings
        @types.each do |name, t|
          if t.kind.fields?
            t.fields.each do |_name, field_defn|
              field_defn.type = resolve_late_binding(field_defn.type)
            end
          end
        end

        @entry_point_fields.each do |name, f|
          f.type = resolve_late_binding(f.type)
        end

        @dynamic_fields.each do |name, f|
          f.type = resolve_late_binding(f.type)
        end
        nil
      end

      private

      def resolve_late_binding(late_bound_type)
        case late_bound_type
        when GraphQL::Schema::LateBoundType
          @schema.find_type(late_bound_type.name)
        when GraphQL::Schema::List, GraphQL::ListType
          resolve_late_binding(late_bound_type.of_type).to_list_type
        when GraphQL::Schema::NonNull, GraphQL::NonNullType
          resolve_late_binding(late_bound_type.of_type).to_non_null_type
        when Module
          # It's a normal type -- no change required
          late_bound_type
        else
          raise "Invariant: unexpected type: #{late_bound_type} (#{late_bound_type.class})"
        end
      end

      def load_constant(class_name)
        const = @custom_namespace.const_get(class_name)
        if @class_based
          dup_type_class(const)
        else
          # Use `.to_graphql` to get a freshly-made version, not shared between schemas
          const.to_graphql
        end
      rescue NameError
        # Dup the built-in so that the cached fields aren't shared
        dup_type_class(@built_in_namespace.const_get(class_name))
      end

      def get_fields_from_class(class_sym:)
        object_type_defn = load_constant(class_sym)

        if object_type_defn.is_a?(Module)
          object_type_defn.fields
        else
          extracted_field_defns = {}
          object_class = object_type_defn.metadata[:type_class]
          object_type_defn.all_fields.each do |field_defn|
            inner_resolve = field_defn.resolve_proc
            resolve_with_instantiate = PerFieldProxyResolve.new(object_class: object_class, inner_resolve: inner_resolve)
            extracted_field_defns[field_defn.name] = field_defn.redefine(resolve: resolve_with_instantiate)
          end
          extracted_field_defns
        end
      end

      # This is probably not 100% robust -- but it has to be good enough to avoid modifying the built-in introspection types
      def dup_type_class(type_class)
        type_name = type_class.graphql_name
        Class.new(type_class) do
          # This won't be inherited like other things will
          graphql_name(type_name)

          if type_class.kind.fields?
            type_class.fields.each do |_name, field_defn|
              dup_field = field_defn.dup
              dup_field.owner = self
              add_field(dup_field)
            end
          end
        end
      end

      class PerFieldProxyResolve
        def initialize(object_class:, inner_resolve:)
          @object_class = object_class
          @inner_resolve = inner_resolve
        end

        def call(obj, args, ctx)
          query_ctx = ctx.query.context
          # Remove the QueryType wrapper
          if obj.is_a?(GraphQL::Schema::Object)
            obj = obj.object
          end
          wrapped_object = @object_class.authorized_new(obj, query_ctx)
          @inner_resolve.call(wrapped_object, args, ctx)
        end
      end
    end
  end
end
