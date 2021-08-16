# frozen_string_literal: true
require "spec_helper"
require "generators/graphql/mutation_generator"
require "generators/graphql/install_generator"

class GraphQLGeneratorsMutationGeneratorTest < BaseGeneratorTest
  tests Graphql::Generators::MutationGenerator

  destination File.expand_path("../../../tmp/dummy", File.dirname(__FILE__))

  def setup(directory = "app/graphql")
    prepare_destination
    FileUtils.cd(File.expand_path("../../../tmp", File.dirname(__FILE__))) do
      `rails new dummy --skip-active-record --skip-test-unit --skip-spring --skip-bundle --skip-webpack-install`
    end

<<<<<<< HEAD
    Graphql::Generators::InstallGenerator.start(["--directory", directory], { destination_root: destination_root })
=======
    FileUtils.cd(destination_root) do
      `mkdir #{directory}`
      `touch #{directory}/dummy_schema.rb`
    end
>>>>>>> test: don't generate complete GraphQL install for faster tests
  end

  UPDATE_NAME_MUTATION = <<-RUBY
module Mutations
  class UpdateName < BaseMutation
    # TODO: define return fields
    # field :post, Types::PostType, null: false

    # TODO: define arguments
    # argument :name, String, required: true

    # TODO: define resolve method
    # def resolve(name:)
    #   { post: ... }
    # end
  end
end
RUBY

  EXPECTED_MUTATION_TYPE = <<-RUBY
module Types
  class MutationType < Types::BaseObject
    field :update_name, mutation: Mutations::UpdateName
    # TODO: remove me
    field :test_field, String, null: false,
      description: "An example field added by the generator"
    def test_field
      "Hello World"
    end
  end
end
RUBY

  NAMESPACED_UPDATE_NAME_MUTATION = <<-RUBY
module Mutations
  class Names::UpdateName < BaseMutation
    # TODO: define return fields
    # field :post, Types::PostType, null: false

    # TODO: define arguments
    # argument :name, String, required: true

    # TODO: define resolve method
    # def resolve(name:)
    #   { post: ... }
    # end
  end
end
RUBY

  NAMESPACED_EXPECTED_MUTATION_TYPE = <<-RUBY
module Types
  class MutationType < Types::BaseObject
    field :update_name, mutation: Mutations::Names::UpdateName
    # TODO: remove me
    field :test_field, String, null: false,
      description: "An example field added by the generator"
    def test_field
      "Hello World"
    end
  end
end
RUBY

  test "it generates an empty resolver by name" do
    setup
    run_generator(["UpdateName"])
    assert_file "app/graphql/mutations/update_name.rb", UPDATE_NAME_MUTATION
  end

  test "it inserts the field into the MutationType" do
    setup
    run_generator(["UpdateName"])
    assert_file "app/graphql/types/mutation_type.rb", EXPECTED_MUTATION_TYPE
  end

  test "it generates and inserts a namespaced resolver" do
    setup
    run_generator(["names/update_name"])
    assert_file "app/graphql/mutations/names/update_name.rb", NAMESPACED_UPDATE_NAME_MUTATION
    assert_file "app/graphql/types/mutation_type.rb", NAMESPACED_EXPECTED_MUTATION_TYPE
  end

  test "it allows for user-specified directory" do
    setup "app/mydirectory"
    run_generator(["UpdateName", "--directory", "app/mydirectory"])

    assert_file "app/mydirectory/mutations/update_name.rb", UPDATE_NAME_MUTATION
  end
end
