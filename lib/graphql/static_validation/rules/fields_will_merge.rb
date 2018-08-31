# frozen_string_literal: true
module GraphQL
  module StaticValidation
    module FieldsWillMerge
      # Validates that a selection set is valid if all fields (including spreading any
      # fragments) either correspond to distinct response names or can be merged
      # without ambiguity.
      #
      # Original Algorithm: https://github.com/graphql/graphql-js/blob/master/src/validation/rules/OverlappingFieldsCanBeMerged.js
      NO_ARGS = {}.freeze
      Field = Struct.new(:node, :definition, :parent_type)

      def initialize(*)
        super
        @visited_fragments = {}
        @compared_fragments = {}
        @fields_and_fragments_from_node = {}
      end

      def on_operation_definition(node, _parent)
        conflicts_within_selection_set(node, type_definition)
        super
      end

      def on_field(node, _parent)
        conflicts_within_selection_set(node, type_definition)
        super
      end

      private

      def conflicts_within_selection_set(node, parent_type)
        return if parent_type.nil?

        fields, fragment_names = fields_and_fragments_from_selection(node, parent_type: parent_type)

        # (A) Find find all conflicts "within" the fields of this selection set.
        find_conflicts_within(fields)

        fragment_names.each_with_index do |fragment_name, i|
          # (B) Then find conflicts between these fields and those represented by
          # each spread fragment name found.
          find_conflicts_between_fields_and_fragment(
            fragment_name,
            fields,
            mutually_exclusive: false,
          )

          # (C) Then compare this fragment with all other fragments found in this
          # selection set to collect conflicts between fragments spread together.
          # This compares each item in the list of fragment names to every other
          # item in that same list (except for itself).
          fragment_names[i + 1..-1].each do |fragment_name2|
            find_conflicts_between_fragments(
              fragment_name,
              fragment_name2,
              mutually_exclusive: false,
            )
          end
        end
      end

      def find_conflicts_between_fragments(fragment_name1, fragment_name2, mutually_exclusive:)
        return if fragment_name1 == fragment_name2

        cache_key = compared_fragments_key(
          fragment_name1,
          fragment_name2,
          mutually_exclusive,
        )
        if @compared_fragments.key?(cache_key)
          return
        else
          @compared_fragments[cache_key] = true
        end

        fragment1 = context.fragments[fragment_name1]
        fragment2 = context.fragments[fragment_name2]

        return if fragment1.nil? || fragment2.nil?

        fragment_type1 = context.schema.types[fragment1.type.name]
        fragment_type2 = context.schema.types[fragment2.type.name]

        return if fragment_type1.nil? || fragment_type2.nil?

        fragment_fields1, fragment_names1 = fields_and_fragments_from_selection(fragment1, parent_type: fragment_type1)
        fragment_fields2, fragment_names2 = fields_and_fragments_from_selection(fragment2, parent_type: fragment_type2)

        # (F) First, find all conflicts between these two collections of fields
        # (not including any nested fragments).
        find_conflicts_between(
          fragment_fields1,
          fragment_fields2,
          mutually_exclusive: mutually_exclusive,
        )

        # (G) Then collect conflicts between the first fragment and any nested
        # fragments spread in the second fragment.
        fragment_names2.each do |fragment_name|
          find_conflicts_between_fragments(
            fragment_name1,
            fragment_name,
            mutually_exclusive: mutually_exclusive,
          )
        end

        # (G) Then collect conflicts between the first fragment and any nested
        # fragments spread in the second fragment.
        fragment_names1.each do |fragment_name|
          find_conflicts_between_fragments(
            fragment_name2,
            fragment_name,
            mutually_exclusive: mutually_exclusive,
          )
        end
      end

      def find_conflicts_between_fields_and_fragment(fragment_name, fields, mutually_exclusive:)
        return if @visited_fragments.key?(fragment_name)
        @visited_fragments[fragment_name] = true

        fragment = context.fragments[fragment_name]
        return if fragment.nil?

        fragment_type = context.schema.types[fragment.type.name]
        return if fragment_type.nil?

        fragment_fields, fragment_fragment_names = fields_and_fragments_from_selection(fragment, parent_type: fragment_type)

        # (D) First find any conflicts between the provided collection of fields
        # and the collection of fields represented by the given fragment.
        find_conflicts_between(
          fields,
          fragment_fields,
          mutually_exclusive: mutually_exclusive,
        )

        # (E) Then collect any conflicts between the provided collection of fields
        # and any fragment names found in the given fragment.
        fragment_fragment_names.each do |fragment_name|
          find_conflicts_between_fields_and_fragment(
            fragment_name,
            fields,
            mutually_exclusive: mutually_exclusive,
          )
        end
      end

      def find_conflicts_within(response_keys)
        response_keys.each do |key, fields|
          next if fields.size < 2
          # find conflicts within nodes
          for i in 0..fields.size - 1
            for j in i + 1..fields.size - 1
              find_conflict(key, fields[i], fields[j])
            end
          end
        end
      end

      def find_conflict(response_key, field1, field2, mutually_exclusive: false)
        binding.pry
        parent_type1 = field1.parent_type
        parent_type2 = field2.parent_type

        node1 = field1.node
        node2 = field2.node

        are_mutually_exclusive = mutually_exclusive ||
                                 (parent_type1 != parent_type2 &&
                                  parent_type1.kind.object? &&
                                  parent_type2.kind.object?)

        if !are_mutually_exclusive
          if node1.name != node2.name
            errored_nodes = [node1.name, node2.name].sort.join(" or ")
            msg = "Field '#{response_key}' has a field conflict: #{errored_nodes}?"
            context.errors << GraphQL::StaticValidation::Message.new(msg, nodes: [node1, node2])
          end

          args = possible_arguments(node1, node2)
          if args.size > 1
            msg = "Field '#{response_key}' has an argument conflict: #{args.map { |arg| GraphQL::Language.serialize(arg) }.join(" or ")}?"
            context.errors << GraphQL::StaticValidation::Message.new(msg, nodes: [node1, node2])
          end
        end

        find_conflicts_between_sub_selection_sets(
          field1,
          field2,
          mutually_exclusive: are_mutually_exclusive,
        )
      end

      def find_conflicts_between_sub_selection_sets(field1, field2, mutually_exclusive:)
        return if field1.definition.nil? || field2.definition.nil?

        fields, fragment_names = fields_and_fragments_from_selection(field1.node, parent_type: field1.definition.type.unwrap)
        fields2, fragment_names2 = fields_and_fragments_from_selection(field2.node, parent_type: field2.definition.type.unwrap)

        # (H) First, collect all conflicts between these two collections of field.
        find_conflicts_between(fields, fields2, mutually_exclusive: mutually_exclusive)

        # (I) Then collect conflicts between the first collection of fields and
        # those referenced by each fragment name associated with the second.
        fragment_names2.each do |fragment_name|
          find_conflicts_between_fields_and_fragment(
            fields,
            fragment_name,
            mutually_exclusive: mutually_exclusive,
          )
        end

        # (I) Then collect conflicts between the second collection of fields and
        # those referenced by each fragment name associated with the first.
        fragment_names.each do |fragment_name|
          find_conflicts_between_fields_and_fragment(
            fields2,
            fragment_name,
            mutually_exclusive: mutually_exclusive,
          )
        end

        # (J) Also collect conflicts between any fragment names by the first and
        # fragment names by the second. This compares each item in the first set of
        # names to each item in the second set of names.
        fragment_names.each do |frag1|
          fragment_names2.each do |frag2|
            find_conflicts_between_fragments(
              frag1,
              frag2,
              mutually_exclusive: mutually_exclusive,
            )
          end
        end
      end

      def find_conflicts_between(response_keys, response_keys2, mutually_exclusive:)
        response_keys.each do |key, fields|
          fields2 = response_keys2[key]
          if fields2
            fields.each do |field|
              fields2.each do |field2|
                find_conflict(
                  key,
                  field,
                  field2,
                  mutually_exclusive: mutually_exclusive,
                )
              end
            end
          end
        end
      end

      def fields_and_fragments_from_selection(node, parent_type:)
        @fields_and_fragments_from_node[node] ||= begin
          fields, fragment_names = find_fields_and_fragments(node.selections, parent_type: parent_type)
          response_keys = fields.group_by { |f| f.node.alias || f.node.name }
          [response_keys, fragment_names]
        end
      end

      def find_fields_and_fragments(selections, parent_type:, fields: [], fragment_names: [])
        selections.each do |node|
          case node
          when GraphQL::Language::Nodes::Field
            definition = context.schema.get_field(parent_type, node.name)
            fields << Field.new(node, definition, parent_type)
          when GraphQL::Language::Nodes::InlineFragment
            fragment_type = node.type ? context.schema.types[node.type.name] : parent_type
            find_fields_and_fragments(node.selections, parent_type: fragment_type, fields: fields, fragment_names: fragment_names) if fragment_type
          when GraphQL::Language::Nodes::FragmentSpread
            fragment_names << node.name
          end
        end

        [fields, fragment_names]
      end

      def possible_arguments(field1, field2)
        # Check for incompatible / non-identical arguments on this node:
        [field1, field2].map do |n|
          if n.arguments.any?
            n.arguments.reduce({}) do |memo, a|
              arg_value = a.value
              memo[a.name] = case arg_value
              when GraphQL::Language::Nodes::AbstractNode
                arg_value.to_query_string
              else
                GraphQL::Language.serialize(arg_value)
              end
              memo
            end
          else
            NO_ARGS
          end
        end.uniq
      end

      def compared_fragments_key(frag1, frag2, exclusive)
        # Cache key to not compare two fragments more than once.
        # The key includes both fragment names sorted (this way we
        # avoid computing "A vs B" and "B vs A"). It also includes
        # "exclusive" since the result may change depending on the parent_type
        "#{[frag1, frag2].sort.join('-')}-#{exclusive}"
      end
    end
  end
end
