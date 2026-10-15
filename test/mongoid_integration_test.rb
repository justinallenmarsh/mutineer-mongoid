# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "json"
require "securerandom"
require "open3"
require "stringio"
require "digest"

# Real MongoDB checks, excluded from the zero-dependency suite. The fixture owns
# its bundle; no Mongoid dependency leaks into the gem or its default tests.
class MongoidIntegrationTest < Minitest::Test
  APP = File.expand_path("fixtures/mongoid_app", __dir__)
  SOURCE = File.join(APP, "invoice.rb")
  SPEC = File.join(APP, "spec/invoice_spec.rb")
  LIB = File.expand_path("../lib", __dir__)

  def setup
    @old_database = ENV["MUTINEER_MONGO_DATABASE"]
    ENV["MUTINEER_MONGO_DATABASE"] = "mutineer_fixture_#{SecureRandom.hex(8)}"
    @databases = databases
    app_script(<<~CODE)
      Invoice.create_indexes
      Invoice.create!(reference: "seed", amount: 7)
    CODE
  end

  def teardown
    @clients&.each(&:quit)
    assert_equal @databases, databases, "disposable databases leaked after the daemon stopped"
    app_script("Mongoid.default_client.database.drop")
    ENV["MUTINEER_MONGO_DATABASE"] = @old_database
  end

  def app_script(code)
    env = ENV.to_h.slice("MUTINEER_MONGO_URL", "MUTINEER_MONGO_DATABASE", "MONGOID_VERSION")
    env["BUNDLE_GEMFILE"] = File.join(APP, "Gemfile")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env,
                    "bundle", "exec", "ruby", "-r", "./boot", "-e", code, chdir: APP)
    end
    assert status.success?, "#{out}\n#{err}"
    out
  end

  def databases
    source = Digest::SHA256.hexdigest(ENV.fetch("MUTINEER_MONGO_DATABASE"))[0, 8]
    JSON.parse(app_script("print Mongoid.default_client.database_names.grep(/\\Amutineer_#{source}_/).sort.to_json"))
  end

  def client(require_paths: [], **overrides)
    boot = { project_root: APP, boot: File.join(APP, "boot.rb"), framework: "rspec", rails: true,
             source_dirs: [APP], load_paths: [APP], require_paths: require_paths }
    boot.merge!(overrides)
    diagnostics = StringIO.new
    handle = Mutineer::DaemonClient.new(boot: boot, app_root: APP, errio: diagnostics).start
    (@clients ||= []) << handle
    [handle, diagnostics]
  end

  def verdict(handle, code: File.read(SOURCE), worker: 0, timeout: 20, tests: [SPEC])
    handle.request(id: worker, payload: { "code" => code, "source_file" => SOURCE },
                   tests: tests, worker: worker, timeout: timeout)
  end

  def test_workers_preserve_seed_and_indexes_without_sharing_writes
    handles = [client, client]
    2.times do
      outcomes = handles.each_with_index.map do |(handle, diagnostics), worker|
        Thread.new { [verdict(handle, worker: worker), diagnostics.string] }
      end.map(&:value)
      assert_equal %w[survived survived], outcomes.map(&:first), outcomes.inspect
    end
    handles.each do |handle, diagnostics|
      assert_equal "killed", verdict(handle, code: File.read(SOURCE).sub("amount * 2", "amount + 2")), diagnostics.string
    end
    assert_equal "[\"seed\"]", app_script('print Invoice.pluck(:reference).to_json')
  end

  def test_timeout_cleanup_and_the_next_mutant_start_fresh
    handle, diagnostics = client
    code = File.read(SOURCE) + "\nInvoice.create!(reference: 'left_by_timeout', amount: 1); sleep 60\n"
    assert_equal "timeout", verdict(handle, code: code, timeout: 1), diagnostics.string
    assert_equal "survived", verdict(handle), diagnostics.string
    assert_equal "[\"seed\"]", app_script('print Invoice.pluck(:reference).to_json')
  end

  def test_payload_failure_is_an_error_and_does_not_kill_a_mutant
    handle, diagnostics = client
    code = File.read(SOURCE) + "\nraise 'payload failed'\n"
    assert_equal "error", verdict(handle, code: code), diagnostics.string
    assert_equal "survived", verdict(handle), diagnostics.string
  end

  def test_connection_failure_is_an_error_instead_of_a_false_kill
    Tempfile.create(["mongoid-connection-failure", ".rb"]) do |file|
      file.write("Mongoid.define_singleton_method(:reconnect_clients) { raise 'connection unavailable' }\n")
      file.flush
      handle, diagnostics = client(require_paths: [file.path])
      assert_equal "error", verdict(handle), diagnostics.string
      assert_includes diagnostics.string, "connection unavailable"
    end
  end

  def test_connection_errors_inside_examples_and_suite_hooks_are_not_kills
    Dir.mktmpdir("mongoid-failure-spec", APP) do |dir|
      spec = File.join(dir, "connection_spec.rb")
      specs = [
        "RSpec.describe(Invoice) { it('queries', :aggregate_failures) { expect(1).to eq(2); raise Mongo::Error::SocketError, 'lost connection' } }",
        "RSpec.describe(Invoice) { it('queries a paused pool') { raise Mongo::Error::PoolPausedError.new('localhost', Object.new) } }",
        "RSpec.configure { |config| config.before(:suite) { raise Mongo::Error::SocketError, 'lost connection' } }; RSpec.describe(Invoice) { it('reads') { expect(Invoice.count).to eq(1) } }"
      ]
      specs.each do |code|
        File.write(spec, code)
        handle, diagnostics = client
        assert_equal "error", verdict(handle, tests: [spec]), diagnostics.string
        assert_includes diagnostics.string, "MongoDB infrastructure failure"
      end
    end
  end

  def test_duplicate_key_failures_still_kill_a_mutant
    Dir.mktmpdir("mongoid-duplicate-spec", APP) do |dir|
      spec = File.join(dir, "duplicate_spec.rb")
      File.write(spec, "RSpec.describe(Invoice) { it('inserts a duplicate') { Invoice.create!(reference: 'seed', amount: 1) } }")
      handle, diagnostics = client
      assert_equal "killed", verdict(handle, tests: [spec]), diagnostics.string
    end
  end

  def test_changed_seed_data_rebuilds_the_cached_coverage_map
    Dir.mktmpdir("mongoid-cache", APP) do |dir|
      source = File.join(dir, "seed_probe.rb")
      spec = File.join(dir, "seed_probe_spec.rb")
      code = <<~CODE
        class SeedProbe
          def value
            if Invoice.find_by(reference: "seed").amount == 7
              11
            else
              22
            end
          end
        end
      CODE
      File.write(source, code)
      File.write(spec, "RSpec.describe(SeedProbe) { it('follows the seed') { expect(SeedProbe.new.value).to eq(Invoice.find_by(reference: 'seed').amount == 7 ? 11 : 22) } }\n")
      config = { coverage: true, sources: [source], tests: [spec], cache_dir: File.join(dir, "cache") }
      first, diagnostics = client(require_paths: [source], **config)
      before = first.coverage
      assert_equal [], before.fetch("failed_clean_tests"), diagnostics.string
      app_script("Invoice.where(reference: 'seed').update_all(amount: 8)")
      second, diagnostics = client(require_paths: [source], **config)
      after = second.coverage
      assert_equal [], after.fetch("failed_clean_tests"), diagnostics.string
      relative = source.delete_prefix("#{APP}/")
      old_branch = "#{relative}:#{code.lines.index { |line| line.strip == '11' } + 1}"
      new_branch = "#{relative}:#{code.lines.index { |line| line.strip == '22' } + 1}"
      assert before.fetch("map").key?(old_branch), before.inspect
      refute before.fetch("map").key?(new_branch), before.inspect
      assert after.fetch("map").key?(new_branch), after.inspect
      refute after.fetch("map").key?(old_branch), after.inspect
    end
  end

  def test_serial_and_parallel_reports_agree_on_kills_and_survivors
    Dir.mktmpdir("mutineer-mongoid-parity") do |cache|
      reports = [1, 2].map do |workers|
        env = ENV.to_h.slice("MUTINEER_MONGO_URL", "MUTINEER_MONGO_DATABASE", "MONGOID_VERSION")
        env["BUNDLE_GEMFILE"] = File.expand_path("../Gemfile", __dir__)
        out, err, status = Bundler.with_unbundled_env do
          Open3.capture3(env,
                        "bundle", "exec", "ruby", "-I#{LIB}", File.join(LIB, "../bin/mutineer"),
                        "run", SOURCE, "--test", SPEC, "--rails", "--boot", File.join(APP, "boot.rb"),
                        "--daemon", "--jobs", workers.to_s, "--cache-dir", cache,
                        "--format", "json", chdir: APP)
        end
        assert status.success?, "#{out}\n#{err}"
        JSON.parse(out)
      end
      assert_equal reports.first.fetch("summary"), reports.last.fetch("summary")
      assert_equal reports.first.fetch("survivors"), reports.last.fetch("survivors")
      assert_operator reports.first.dig("summary", "killed"), :>, 0
      assert_operator reports.first.dig("summary", "survived"), :>, 0
      %w[errored timeout uncapturable].each do |key|
        assert_equal 0, reports.first.dig("summary", key)
      end
    end
  end

  def test_adapter_rejects_non_test_environments_and_multiple_clients
    code = <<~CODE
      require #{File.join(LIB, 'mutineer/mongoid_worker_db').inspect}
      ENV['RAILS_ENV'] = 'development'
      begin
        Mutineer::MongoidWorkerDb.new
      rescue => error
        puts error.message
      end
      ENV['RAILS_ENV'] = 'test'
      Mongoid.load_configuration(clients: Mongoid.clients.merge(other: Mongoid.clients.fetch(:default)))
      begin
        Mutineer::MongoidWorkerDb.new
      rescue => error
        puts error.message
      end
    CODE
    output = app_script(code)
    assert_includes output, "require RAILS_ENV=test"
    assert_includes output, "one default client only"
  end
end
