# frozen_string_literal: true

require_relative "test_runners/rspec"

module Mutineer
  # Separates MongoDB infrastructure failures from assertions that kill mutants.
  # Loaded only in daemon children. Duplicate-key and other application errors
  # still kill mutants; connection failures and server failovers do not.
  module MongoidFailures
    # Driver errors describing unavailable connections or authentication.
    CONNECTION_ERRORS = %w[
      Mongo::Error::SocketError Mongo::Error::SocketTimeoutError
      Mongo::Error::NoServerAvailable Mongo::Error::ConnectionCheckOutTimeout
      Mongo::Error::ConnectionUnavailable Mongo::Error::ConnectionPerished
      Mongo::Error::PoolError Mongo::Error::TimeoutError
      Mongo::Error::NoServiceConnectionAvailable Mongo::Error::MissingConnection
      Mongo::Error::ClientClosed Mongo::Error::AuthError
    ].freeze
    # Retryable server/network failures; excludes duplicate-key and validation codes.
    SERVER_CODES = [6, 7, 89, 91, 189, 10107, 11600, 11602, 13435, 13436].freeze

    # Observe both examples and suite hooks before RSpec flattens their failures.
    # @param tests [Array<String>] covering spec files.
    # @return [Integer] 0 survived, 1 assertion/application failure, 2 infrastructure.
    def self.run(tests)
      require "rspec/core"
      ::RSpec::Core::Reporter.prepend(Reporter) unless ::RSpec::Core::Reporter < Reporter
      @failure = nil
      status = TestRunners::RSpec.run(tests)
      if @failure
        warn "[mutineer] MongoDB infrastructure failure: #{@failure.class}"
        2
      else
        status
      end
    end

    # Inspect aggregate failures and exception causes without looping on a cycle.
    # @param exception [Exception, nil] failure reported by RSpec.
    # @return [void]
    def self.record(exception)
      pending = [exception].compact
      seen = {}
      until pending.empty?
        error = pending.pop
        next if seen[error.object_id]

        seen[error.object_id] = true
        @failure = error if infrastructure_error?(error)
        pending << error.cause if error.cause
        pending.concat(error.all_exceptions) if error.respond_to?(:all_exceptions)
      end
    end

    # Match actual driver classes, including subclasses, without requiring Mongo.
    # @param error [Exception] reported exception.
    # @return [Boolean]
    def self.infrastructure_error?(error)
      names = error.class.ancestors.map(&:name)
      CONNECTION_ERRORS.any? { |name| names.include?(name) } ||
        (names.include?("Mongo::Error::OperationFailure") && SERVER_CODES.include?(error.code))
    end

    # RSpec reports suite-hook exceptions separately from failed examples.
    module Reporter
      # @param example [RSpec::Core::Example] failed example.
      # @return [Object] RSpec's notification result.
      def example_failed(example)
        MongoidFailures.record(example.exception)
        super
      end

      # @param exception [Exception] exception raised outside an example.
      # @param context_description [String] RSpec's hook description.
      # @return [Object] RSpec's notification result.
      def notify_non_example_exception(exception, context_description)
        MongoidFailures.record(exception)
        super
      end
    end
  end
end
