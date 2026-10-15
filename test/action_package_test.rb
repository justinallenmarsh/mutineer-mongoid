# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"
require "tmpdir"
require "rbconfig"

# Exercise the action's real install step with an isolated GEM_HOME: the action
# must ship the fork it was pinned to, without a RubyGems publication.
class ActionPackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  INSTALL = YAML.load_file(File.join(ROOT, "action.yml")).dig("runs", "steps", 0, "run")

  def test_installs_the_bundled_fork_into_an_isolated_gem_home
    Dir.mktmpdir("mutineer-action-package") do |dir|
      env = { "ACTION_PATH" => ROOT, "VERSION" => Mutineer::VERSION,
              "RUNNER_TEMP" => dir, "GITHUB_OUTPUT" => File.join(dir, "outputs"), "GEM_HOME" => File.join(dir, "gems"), "GEM_PATH" => File.join(dir, "gems") }
      out, err, status = Bundler.with_unbundled_env do
        Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", INSTALL, chdir: dir)
      end
      assert status.success?, "#{out}\n#{err}"
      executable = File.read(env.fetch("GITHUB_OUTPUT")).lines.find { |line| line.start_with?("executable=") }.split("=", 2).last.strip
      out, err, status = Bundler.with_unbundled_env do
        Open3.capture3(env, RbConfig.ruby, executable, "--version", chdir: dir)
      end
      assert status.success?, "#{out}\n#{err}"
      assert_equal Mutineer::VERSION, out.strip
      refute Dir.exist?(File.join(dir, "gems")), "the action installed into the consumer's gem home"
    end
  end

  def test_refuses_a_version_that_does_not_match_the_pinned_action
    Dir.mktmpdir("mutineer-action-package") do |dir|
      env = { "ACTION_PATH" => ROOT, "VERSION" => "0.0.0", "RUNNER_TEMP" => dir,
              "GEM_HOME" => File.join(dir, "gems"), "GEM_PATH" => File.join(dir, "gems") }
      out, err, status = Bundler.with_unbundled_env do
        Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", INSTALL, chdir: dir)
      end
      assert_equal 2, status.exitstatus, "#{out}\n#{err}"
      assert_includes out, "does not match this action's bundled gem"
      refute Dir.exist?(File.join(dir, "gems")), "a mismatched version installed a gem"
    end
  end
end
