# frozen_string_literal: true
require "spec_helper"

if Fiber.respond_to?(:scheduler) # Ruby 3+
  require_relative "./dummy_scheduler"

  describe GraphQL::Dataloader::AsyncDataloader do
    class AsyncSchema < GraphQL::Schema
      class SleepSource < GraphQL::Dataloader::Source
        def fetch(keys)
          max_sleep = keys.max
          `sleep #{max_sleep}`
          keys.map { |_k| max_sleep }
        end
      end

      class WaitForSource < GraphQL::Dataloader::Source
        def initialize(tag)
          @tag = tag
        end

        def fetch(waits)
          max_wait = waits.max
          puts "[#{Time.now.to_f}] Waiting #{max_wait} for #{@tag}"
          `sleep #{max_wait}`
          puts "[#{Time.now.to_f}] Finished for #{@tag}"
          waits.map { |_w| @tag }
        end
      end

      class Sleeper < GraphQL::Schema::Object
        field :sleeper, Sleeper, null: false, resolver_method: :sleep do
          argument :duration, Float, required: true
        end

        def sleep(duration:)
          `sleep #{duration}`
          duration
        end

        field :duration, Float, null: false
        def duration; object; end
      end

      class Waiter < GraphQL::Schema::Object
        field :wait_for, Waiter, null: false do
          argument :tag, String, required: true
          argument :wait, Float, required: true
        end

        def wait_for(tag:, wait:)
          dataloader.with(WaitForSource, tag).load(wait)
        end

        field :tag, String, null: false
        def tag
          object
        end
      end

      class Query < GraphQL::Schema::Object
        field :sleep, Float, null: false do
          argument :duration, Float, required: true
        end

        field :sleeper, Sleeper, null: false, resolver_method: :sleep do
          argument :duration, Float, required: true
        end

        def sleep(duration:)
          `sleep #{duration}`
          duration
        end

        field :wait_for, Waiter, null: false do
          argument :tag, String, required: true
          argument :wait, Float, required: true
        end

        def wait_for(tag:, wait:)
          dataloader.with(WaitForSource, tag).load(wait)
        end
      end

      query(Query)
      use GraphQL::Dataloader::AsyncDataloader
    end

    def with_scheduler
      prev_scheduler = Fiber.scheduler
      Fiber.set_scheduler(DummyScheduler.new)
      yield
    ensure
      Fiber.set_scheduler(prev_scheduler)
    end

    it "runs IO in parallel by default" do
      dataloader = GraphQL::Dataloader::AsyncDataloader.new
      results = {}
      dataloader.append_job { `sleep 0.1`; results[:a] = 1 }
      dataloader.append_job { `sleep 0.2`; results[:b] = 2 }
      dataloader.append_job { `sleep 0.3`; results[:c] = 3 }

      assert_equal({}, results, "Nothing ran yet")
      started_at = Time.now
      with_scheduler { dataloader.run }
      ended_at = Time.now

      assert_equal({ a: 1, b: 2, c: 3 }, results, "All the jobs ran")
      assert_in_delta 0.3, ended_at - started_at, 0.05, "IO ran in parallel"
    end

    it "works with sources" do
      dataloader = GraphQL::Dataloader::AsyncDataloader.new
      r1 = dataloader.with(AsyncSchema::SleepSource).request(0.1)
      r2 = dataloader.with(AsyncSchema::SleepSource).request(0.2)
      r3 = dataloader.with(AsyncSchema::SleepSource).request(0.3)

      v1 = nil
      dataloader.append_job {
        v1 = r1.load
      }
      started_at = Time.now
      with_scheduler { dataloader.run }
      ended_at = Time.now
      assert_equal 0.3, v1
      started_at_2 = Time.now
      # These should take no time at all since they're already resolved
      v2 = r2.load
      v3 = r3.load
      ended_at_2 = Time.now

      assert_equal 0.3, v2
      assert_equal 0.3, v3
      assert_in_delta 0.0, started_at_2 - ended_at_2, 0.05, "Already-loaded values returned instantly"

      assert_in_delta 0.3, ended_at - started_at, 0.05, "IO ran in parallel"
    end

    it "works with GraphQL" do
      started_at = Time.now
      res = with_scheduler {
        AsyncSchema.execute("{ s1: sleep(duration: 0.1) s2: sleep(duration: 0.2) s3: sleep(duration: 0.3) }")
      }
      ended_at = Time.now
      assert_equal({"s1"=>0.1, "s2"=>0.2, "s3"=>0.3}, res["data"])
      assert_in_delta 0.3, ended_at - started_at, 0.05, "IO ran in parallel"
    end

    it "nested fields don't wait for slower higher-level fields" do
      query_str = <<-GRAPHQL
      {
        s1: sleeper(duration: 0.1) {
          sleeper(duration: 0.1) {
            sleeper(duration: 0.1) {
              duration
            }
          }
        }
        s2: sleeper(duration: 0.2) {
          sleeper(duration: 0.1) {
            duration
          }
        }
        s3: sleeper(duration: 0.3) {
          duration
        }
      }
      GRAPHQL
      started_at = Time.now
      res = with_scheduler {
        AsyncSchema.execute(query_str)
      }
      ended_at = Time.now

      expected_data = {
        "s1" => { "sleeper" => { "sleeper" => { "duration" => 0.1 } } },
        "s2" => { "sleeper" => { "duration" => 0.1 } },
        "s3" => { "duration" => 0.3 }
      }
      assert_equal expected_data, res["data"]
      assert_in_delta 0.3, ended_at - started_at, 0.05, "Fields ran without any waiting"
    end

    it "runs dataloaders in parallel across branches" do
      query_str = <<-GRAPHQL
      {
        w1: waitFor(tag: "a", wait: 0.2) {
          waitFor(tag: "b", wait: 0.2) {
            waitFor(tag: "c", wait: 0.2) {
              tag
            }
          }
        }
        # After the first, these are returned eagerly from cache
        w2: waitFor(tag: "a", wait: 0.2) {
          waitFor(tag: "a", wait: 0.2) {
            waitFor(tag: "a", wait: 0.2) {
              tag
            }
          }
        }
        w3: waitFor(tag: "a", wait: 0.2) {
          waitFor(tag: "b", wait: 0.2) {
            waitFor(tag: "d", wait: 0.2) {
              tag
            }
          }
        }
        w4: waitFor(tag: "e", wait: 0.6) {
          tag
        }
      }
      GRAPHQL
      started_at = Time.now
      res = with_scheduler do
        AsyncSchema.execute(query_str)
      end
      ended_at = Time.now

      expected_data = {
        "w1" => { "waitFor" => { "waitFor" => { "tag" => "c" } } },
        "w2" => { "waitFor" => { "waitFor" => { "tag" => "a" } } },
        "w3" => { "waitFor" => { "waitFor" => { "tag" => "d" } } },
        "w4" => { "tag" => "e" }
      }
      assert_equal expected_data, res["data"]
      # TODO: currently, it's not resuming execution _until_ all dataloaders are finished.
      # The two calls to scheduler.run have to be united into one, called at the very end of `#run`
      assert_in_delta 0.6, ended_at - started_at, 0.05, "Sources were executed in parallel"
    end
  end
end
