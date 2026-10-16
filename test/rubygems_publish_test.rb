# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"
require "rubygems/package"
require "digest"
require "json"

class RubygemsPublishTest < Minitest::Test
  WORKFLOW = YAML.load_file(File.expand_path("../.github/workflows/rubygems.yml", __dir__))
  ROOT = File.expand_path("..", __dir__)

  def test_only_stable_release_tags_are_accepted
    %w[v2.0.0 v12.30.4 main v2 v2.0.0-rc1 v2.0.0.1].each do |tag|
      _out, _err, status = run_step("Validate release tag", ROOT, "RELEASE_TAG" => tag)
      assert_equal %w[v2.0.0 v12.30.4].include?(tag), status.success?, tag
    end
  end

  def test_artifact_must_match_its_checksum_name_and_tag_version
    with_artifact do |dir, filename|
      out, err, status = run_step("Verify release artifact", dir)
      assert status.success?, "#{out}\n#{err}"
      File.write(File.join(dir, "dist/SHA256SUMS"), "0" * 64 + "  #{filename}\n")
      _out, err, status = run_step("Verify release artifact", dir)
      refute status.success?
      assert_includes err, "Release checksum mismatch"
    end
    with_artifact(version: "99.0.0") do |dir, _filename|
      _out, err, status = run_step("Verify release artifact", dir)
      refute status.success?
      assert_includes err, "Release gem name/version mismatch"
    end
  end

  def test_repeated_publication_only_accepts_the_identical_artifact
    with_artifact do |dir, filename|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      curl = File.join(bin, "curl")
      File.write(curl, "#!/bin/sh\nprintf '%s' \"$TEST_RESPONSE\" > published.json\nprintf '%s' \"$TEST_HTTP_STATUS\"\n")
      File.chmod(0o755, curl)
      output = File.join(dir, "outputs")
      env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "GITHUB_OUTPUT" => output,
              "TEST_HTTP_STATUS" => "200", "TEST_RESPONSE" => { sha: Digest::SHA256.file(File.join(dir, "dist", filename)).hexdigest }.to_json }
      _out, err, status = run_step("Check whether this exact gem is already published", dir, env)
      assert status.success?, err
      assert_equal "push=false\n", File.read(output)
      env["TEST_RESPONSE"] = { sha: "different" }.to_json
      _out, err, status = run_step("Check whether this exact gem is already published", dir, env)
      refute status.success?
      assert_includes err, "RubyGems already contains a different artifact"
      File.delete(output)
      env["TEST_HTTP_STATUS"] = "404"
      _out, err, status = run_step("Check whether this exact gem is already published", dir, env)
      assert status.success?, err
      assert_equal "push=true\n", File.read(output)
      env["TEST_HTTP_STATUS"] = "503"
      _out, _err, status = run_step("Check whether this exact gem is already published", dir, env)
      refute status.success?
    end
  end

  private
    def run_step(name, dir, env = {})
      step = WORKFLOW.dig("jobs", "publish", "steps").find { |entry| entry["name"] == name }
      Open3.capture3({ "RELEASE_TAG" => "v#{Mutineer::VERSION}" }.merge(env), "bash", "-euo", "pipefail", "-c", step.fetch("run"), chdir: dir)
    end

    def with_artifact(version: Mutineer::VERSION)
      Dir.mktmpdir("mutineer-publish") do |dir|
        FileUtils.mkdir_p(File.join(dir, "dist"))
        filename = "mutineer-mongoid-#{Mutineer::VERSION}.gem"
        package = File.join(dir, "dist", filename)
        Dir.chdir(ROOT) do
          spec = Gem::Specification.load("mutineer.gemspec")
          spec.version = version
          capture_io { Gem::Package.build(spec, false, false, package) }
        end
        File.write(File.join(dir, "dist/SHA256SUMS"), "#{Digest::SHA256.file(package).hexdigest}  #{filename}\n")
        yield dir, filename
      end
    end
end
