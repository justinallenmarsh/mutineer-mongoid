# frozen_string_literal: true

require "mongoid"
require "uri"
ENV["RAILS_ENV"] = "test"
uri = URI(ENV.fetch("MUTINEER_MONGO_URL", "mongodb://127.0.0.1:27017"))
uri.path = "/#{ENV.fetch('MUTINEER_MONGO_DATABASE', 'mutineer_fixture')}"
Mongoid.configure do |config|
  config.load_configuration(clients: {
    default: {
      uri: uri.to_s,
      options: { server_selection_timeout: 5 }
    }
  })
end
require_relative "invoice"
