# frozen_string_literal: true

require "securerandom"
require "digest"

module Mutineer
  # Isolates Mongoid test runs in disposable databases, one per fork. Uses only
  # the application's Mongoid and driver; neither is a runtime gem dependency.
  # The boot-time snapshot includes documents and indexes. Every child starts
  # from that snapshot, including after a killed or timed-out mutant.
  class MongoidWorkerDb
    # True only when the application has already loaded Mongoid.
    # @return [Boolean]
    def self.available?
      defined?(Mongoid::Clients) ? true : false
    end

    # Capture the test database without writing to it. Multiple clients and
    # mixed ActiveRecord/Mongoid applications fail before any suite can run.
    # @raise [RuntimeError] for an unsupported or non-test configuration.
    def initialize
      raise "Mongoid worker databases require RAILS_ENV=test" unless ENV["RAILS_ENV"] == "test"
      unless Mongoid.clients.keys.map(&:to_s) == ["default"]
        raise "Mongoid worker databases support one default client only"
      end
      if defined?(ActiveRecord::Base)
        raise "Mongoid worker databases do not support mixed ActiveRecord/Mongoid applications"
      end

      @client = Mongoid.default_client
      source = Digest::SHA256.hexdigest(@client.database.name)[0, 8]
      @prefix = "mutineer_#{source}_#{SecureRandom.hex(8)}_"
      @snapshot = @client.database.list_collections.map do |info|
        options = info.fetch("options", {})
        if info["type"] != "collection" || options.key?("timeseries")
          raise "Mongoid worker databases support ordinary collections only (#{info['name']})"
        end

        collection = @client[info.fetch("name")]
        indexes = collection.indexes.to_a.reject { |index| index["name"] == "_id_" }
        [collection.name, options, collection.find.to_a, indexes]
      end
      before_fork
    end

    # Seed documents, indexes and collection options all affect coverage.
    # @return [String] opaque digest; no database contents are persisted in the cache.
    def coverage_cache_key
      Digest::SHA256.hexdigest(Marshal.dump(@snapshot))
    end

    # Close parent sockets before a fork, as required by the Mongoid driver.
    # @return [void]
    def before_fork
      Mongoid.disconnect_clients
    end

    # Route the child before any specs load; failures become infrastructure
    # errors rather than mutation kills. A fresh database needs no schema.rb.
    # @param worker [Integer] worker slot (unused: process ids isolate children).
    # @param schema_path [String, nil] ActiveRecord compatibility argument.
    # @param seed [Boolean] ActiveRecord compatibility argument; always seeds.
    # @return [void]
    def after_fork(worker = 0, schema_path = nil, seed: true)
      Mongoid.reconnect_clients
      client = @client.use(database_name(Process.pid))
      client.database.command(ping: 1)
      Mongoid::Clients.set(:default, client)
      Mongoid.override_database(client.database.name)
      @snapshot.each do |name, options, documents, indexes|
        client[name].create(**options.transform_keys(&:to_sym))
        client[name].insert_many(documents) unless documents.empty?
        indexes.each do |index|
          attributes = index.reject { |key, _| %w[key v ns].include?(key) }.transform_keys(&:to_sym)
          client[name].indexes.create_one(index.fetch("key"), **attributes)
        end
      end
    end

    # Parent-side cleanup runs after the child is reaped, even on timeout.
    # Only this instance's random database prefix can be targeted.
    # @param pid [Integer] the reaped child's process id.
    # @return [void]
    def cleanup(pid)
      @client.use(database_name(pid)).database.drop
    ensure
      before_fork
    end

    # Exact disposable name for one child. Never accepts a database name.
    # @param pid [Integer] child process id.
    # @return [String]
    def database_name(pid)
      "#{@prefix}#{Integer(pid)}"
    end
  end
end
