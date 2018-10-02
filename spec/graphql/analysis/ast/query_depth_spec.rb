# frozen_string_literal: true
require "spec_helper"

describe GraphQL::Analysis::AST::QueryDepth do
  let(:result) { GraphQL::Analysis::AST.analyze_query(query, [GraphQL::Analysis::AST::QueryDepth]) }
  let(:query) { GraphQL::Query.new(Dummy::Schema, query_string, variables: variables) }
  let(:variables) { {} }

  describe "simple queries" do
    let(:query_string) {%|
      query cheeses($isIncluded: Boolean = true){
        # depth of 2
        cheese1: cheese(id: 1) {
          id
          flavor
        }

        # depth of 4
        cheese2: cheese(id: 2) @include(if: $isIncluded) {
          similarCheese(source: SHEEP) {
            ... on Cheese {
              similarCheese(source: SHEEP) {
                id
              }
            }
          }
        }
      }
    |}

    it "finds the max depth" do
      depth = result.first
      assert_equal 4, depth
    end

    describe "with directives" do
      let(:variables) { { "isIncluded" => false } }

      it "doesn't count skipped fields" do
        assert_equal 2, result.first
      end
    end
  end

  describe "query with fragments" do
    let(:query_string) {%|
      {
        # depth of 2
        cheese1: cheese(id: 1) {
          id
          flavor
        }

        # depth of 4
        cheese2: cheese(id: 2) {
          ... cheeseFields1
        }
      }

      fragment cheeseFields1 on Cheese {
        similarCheese(source: COW) {
          id
          ... cheeseFields2
        }
      }

      fragment cheeseFields2 on Cheese {
        similarCheese(source: SHEEP) {
          id
        }
      }
    |}

    it "finds the max depth" do
      assert_equal 4, result.first
    end
  end
end
