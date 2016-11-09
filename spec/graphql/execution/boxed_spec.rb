require "spec_helper"

describe GraphQL::Execution::Boxed do
  class Box
    def initialize(item)
      @item = item
    end

    def item
      @item
    end
  end

  class SumAll
    attr_reader :own_value
    attr_accessor :value

    def initialize(ctx, own_value)
      @own_value = own_value
      @all = ctx[:__sum_all__] ||= []
      @all << self
    end

    def value
      @value ||= begin
        total_value = @all.map(&:own_value).reduce(&:+)
        @all.each { |v| v.value = total_value}
        @all.clear
        total_value
      end
      @value
    end
  end

  BoxedSum = GraphQL::ObjectType.define do
    name "BoxedSum"
    field :value, types.Int do
      resolve ->(o, a, c) { o == 13 ? nil : o }
    end
    field :nestedSum, !BoxedSum do
      argument :value, !types.Int
      resolve ->(o, args, c) {
        if args[:value] == 13
          Box.new(nil)
        else
          SumAll.new(c, o + args[:value])
        end
      }
    end

    field :nullableNestedSum, BoxedSum do
      argument :value, types.Int
      resolve ->(o, args, c) {
        if args[:value] == 13
          Box.new(nil)
        else
          SumAll.new(c, o + args[:value])
        end
      }
    end
  end

  BoxedQuery = GraphQL::ObjectType.define do
    name "Query"
    field :int, !types.Int do
      argument :value, !types.Int
      argument :plus, types.Int, default_value: 0
      resolve ->(o, a, c) { Box.new(a[:value] + a[:plus])}
    end

    field :nestedSum, !BoxedSum do
      argument :value, !types.Int
      resolve ->(o, args, c) { SumAll.new(c, args[:value]) }
    end

    field :nullableNestedSum, BoxedSum do
      argument :value, types.Int
      resolve ->(o, args, c) { SumAll.new(c, args[:value]) }
    end

    field :listSum, types[BoxedSum] do
      argument :values, types[types.Int]
      resolve ->(o, args, c) { args[:values] }
    end
  end

  BoxedSchema = GraphQL::Schema.define do
    query(BoxedQuery)
    mutation(BoxedQuery)
    boxed_value(Box, :item)
    boxed_value(SumAll, :value)
  end

  def run_query(query_str)
    BoxedSchema.execute(query_str)
  end

  describe "unboxing" do
    it "calls value handlers" do
      res = run_query('{  int(value: 2, plus: 1)}')
      assert_equal 3, res["data"]["int"]
    end

    it "can do nested boxed values" do
      res = run_query %|
      {
        a: nestedSum(value: 3) {
          value
          nestedSum(value: 7) {
            value
          }
        }
        b: nestedSum(value: 2) {
          value
          nestedSum(value: 11) {
            value
          }
        }

        c: listSum(values: [1,2]) {
          nestedSum(value: 3) {
            value
          }
        }
      }
      |

      expected_data = {
        "a"=>{"value"=>14, "nestedSum"=>{"value"=>46}},
        "b"=>{"value"=>14, "nestedSum"=>{"value"=>46}},
        "c"=>[{"nestedSum"=>{"value"=>14}}, {"nestedSum"=>{"value"=>14}}],
      }

      assert_equal expected_data, res["data"]
    end

    it "propagates nulls" do
      res = run_query %|
      {
        nestedSum(value: 1) {
          value
          nestedSum(value: 13) {
            value
          }
        }
      }|

      assert_equal(nil, res["data"])
      assert_equal 1, res["errors"].length


      res = run_query %|
      {
        nullableNestedSum(value: 1) {
          value
          nullableNestedSum(value: 2) {
            nestedSum(value: 13) {
              value
            }
          }
        }
      }|

      pp res
      expected_data = {
        "nullableNestedSum" => {
          "value" => 1,
          "nullableNestedSum" => nil,
        }
      }
      assert_equal(expected_data, res["data"])
      assert_equal 1, res["errors"].length

    end

    it "resolves mutation fields right away" do
      res = run_query %|
      {
        a: nestedSum(value: 2) { value }
        b: nestedSum(value: 4) { value }
        c: nestedSum(value: 6) { value }
      }|

      assert_equal [12, 12, 12], res["data"].values.map { |d| d["value"] }

      res = run_query %|
      mutation {
        a: nestedSum(value: 2) { value }
        b: nestedSum(value: 4) { value }
        c: nestedSum(value: 6) { value }
      }
      |

      assert_equal [2, 4, 6], res["data"].values.map { |d| d["value"] }
    end
  end

  describe "BoxMethodMap" do
    class SubBox < Box; end

    let(:map) { GraphQL::Execution::Boxed::BoxMethodMap.new }

    it "finds methods for classes and subclasses" do
      map.set(Box, :item)
      map.set(SumAll, :value)
      b = Box.new(1)
      sub_b = SubBox.new(2)
      s = SumAll.new({}, 3)
      assert_equal(:item, map.get(b))
      assert_equal(:item, map.get(sub_b))
      assert_equal(:value, map.get(s))
    end
  end
end
