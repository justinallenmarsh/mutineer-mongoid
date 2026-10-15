# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"

# Run the release guards against real temporary Git repositories and remotes.
class ReleaseTagTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/release.yml", __dir__)

  def test_major_tag_does_not_move_to_an_older_release
    with_history(current: "1.9.0") do |dir, remote|
      before = git(dir, "ls-remote", remote, "refs/tags/v1")
      out, err, status = run_step(dir, "Move floating major tag")
      assert status.success?, "#{out}\n#{err}"
      assert_includes out, "Keeping the newer v1 release (1.9.0)"
      assert_equal before, git(dir, "ls-remote", remote, "refs/tags/v1")
    end
  end

  def test_major_tag_moves_forward
    with_history(current: "1.6.0") do |dir, remote|
      out, err, status = run_step(dir, "Move floating major tag")
      assert status.success?, "#{out}\n#{err}"
      expected = git(dir, "rev-parse", "v1.7.0").strip
      assert_equal expected, git(dir, "ls-remote", remote, "refs/tags/v1").split.first
    end
  end

  def test_first_release_creates_the_major_tag
    with_history(current: nil) do |dir, remote|
      out, err, status = run_step(dir, "Move floating major tag")
      assert status.success?, "#{out}\n#{err}"
      expected = git(dir, "rev-parse", "v1.7.0").strip
      assert_equal expected, git(dir, "ls-remote", remote, "refs/tags/v1").split.first
    end
  end

  def test_release_refuses_a_tagged_commit_outside_main
    with_history(current: "1.6.0", on_main: false) do |dir, _remote|
      out, err, status = run_step(dir, "Guard release ancestry")
      assert_equal 1, status.exitstatus, "#{out}\n#{err}"
      assert_includes out, "release commit is not on main"
    end
  end

  def test_release_accepts_a_tagged_commit_on_main
    with_history(current: "1.6.0") do |dir, _remote|
      out, err, status = run_step(dir, "Guard release ancestry")
      assert status.success?, "#{out}\n#{err}"
    end
  end

  def with_history(current:, on_main: true)
    Dir.mktmpdir("mutineer-release-tags") do |root|
      remote = File.join(root, "remote.git")
      dir = File.join(root, "work")
      FileUtils.mkdir_p(dir)
      git(root, "init", "--bare", "-q", remote)
      git(dir, "init", "-q", "-b", "main")
      git(dir, "config", "user.name", "Release test")
      git(dir, "config", "user.email", "release@example.test")
      git(dir, "remote", "add", "origin", remote)
      FileUtils.mkdir_p(File.join(dir, "lib/mutineer"))
      version_file = File.join(dir, "lib/mutineer/version.rb")
      File.write(version_file, "module Mutineer; VERSION = \"#{current || '1.6.0'}\"; end\n")
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "Initial release")
      git(dir, "push", "-q", "origin", "main")
      if current
        git(dir, "tag", "v1")
        git(dir, "push", "-q", "origin", "refs/tags/v1")
      end
      git(dir, "switch", "-qc", "candidate") unless on_main
      File.write(version_file, "module Mutineer; VERSION = \"1.7.0\"; end\n")
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "Next release")
      git(dir, "tag", "v1.7.0")
      git(dir, "push", "-q", "origin", "HEAD", "refs/tags/v1.7.0")
      yield dir, remote
    end
  end

  def run_step(dir, name)
    script = YAML.load_file(WORKFLOW).dig("jobs", "release", "steps").find { |step| step["name"] == name }.fetch("run")
    env = { "GITHUB_REF_NAME" => "v1.7.0", "GITHUB_SHA" => git(dir, "rev-parse", "HEAD").strip }
    Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", script, chdir: dir)
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    assert status.success?, "git #{args.join(' ')}: #{out}\n#{err}"
    out
  end
end
