module GraphQL
  class ObjectType
    def connection_type
      @connection_type ||= GraphQL::Relay::BaseConnection.create_type(self)
    end
  end
end
