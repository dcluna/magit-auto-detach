require "test_helper"
require "shellwords"
require "mad/state"

class MadRestoreTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = File.realpath(Dir.mktmpdir("mad-restore-test"))
    @repo = create_test_repo(@dir)
    @state_file = File.join(File.expand_path(git_common_dir(@repo), @repo), "magit-auto-detach.json")
    run_script("mad-detach", "main", "feat-c", "--repo", @repo)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_restores_all_worktrees
    output, status = run_script("mad-restore", "--repo", @repo)
    assert status.success?, "Expected success: #{output}"

    { "wt-feat-a" => "feat-a", "wt-feat-b" => "feat-b", "wt-feat-c" => "feat-c" }.each do |wt, branch|
      actual = `git -C #{Shellwords.escape(File.join(@dir, wt))} symbolic-ref --short HEAD 2>&1`.strip
      assert_equal branch, actual, "#{wt} should be on #{branch}"
    end
  end

  def test_deletes_state_file
    run_script("mad-restore", "--repo", @repo)
    refute File.exist?(@state_file)
  end

  def test_outputs_json_summary
    output, _ = run_script("mad-restore", "--repo", @repo)
    summary = JSON.parse(output)
    assert summary.key?("restored")
    assert_equal 3, summary["restored"].length
  end

  def test_no_state_file_message
    File.delete(@state_file)
    output, status = run_script("mad-restore", "--repo", @repo)
    assert status.success?
    assert_match(/nothing to restore/i, output)
  end

  def test_partial_restore_on_failure
    git(@repo, "branch", "-D", "feat-b")

    output, status = run_script("mad-restore", "--repo", @repo)
    assert_equal 1, status.exitstatus, "Expected exit 1 for partial restore"

    branch_a = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-a"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-a", branch_a

    branch_c = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-c"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-c", branch_c

    assert File.exist?(@state_file)
    data = JSON.parse(File.read(@state_file))
    assert_equal 1, data["entries"].length
    assert_equal "feat-b", data["entries"][0]["branch"]
  end

  def test_dry_run
    output, status = run_script("mad-restore", "--repo", @repo, "--dry-run")
    assert status.success?
    head = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-a"))} symbolic-ref HEAD 2>&1`
    refute $?.success?, "Should still be detached"
    assert File.exist?(@state_file)
  end
end
