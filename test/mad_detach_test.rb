require "test_helper"
require "shellwords"
require "mad/state"

class MadDetachTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = File.realpath(Dir.mktmpdir("mad-detach-test"))
    @repo = create_test_repo(@dir)
    @state_file = File.join(File.expand_path(git_common_dir(@repo), @repo), "magit-auto-detach.json")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_detaches_all_worktrees
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert status.success?, "Expected success: #{output}"

    %w[wt-feat-a wt-feat-b wt-feat-c].each do |wt|
      head_output = `git -C #{Shellwords.escape(File.join(@dir, wt))} symbolic-ref HEAD 2>&1`
      refute $?.success?, "#{wt} should be detached"
    end
  end

  def test_creates_state_file
    run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert File.exist?(@state_file), "State file should exist"
    data = JSON.parse(File.read(@state_file))
    assert_equal 2, data["version"]
    assert_equal [["main", "feat-c"]], data["ranges"]
    assert_equal 3, data["entries"].length
    branches = data["entries"].map { |e| e["branch"] }
    assert_includes branches, "feat-a"
    assert_includes branches, "feat-b"
    assert_includes branches, "feat-c"
  end

  def test_outputs_json_summary
    output, _ = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    summary = JSON.parse(output)
    assert summary.key?("detached")
    assert_equal 3, summary["detached"].length
  end

  def test_no_worktrees_noop
    %w[feat-a feat-b feat-c].each do |branch|
      git(@repo, "worktree", "remove", File.join(@dir, "wt-#{branch}"))
    end
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert status.success?
    refute File.exist?(@state_file), "No state file for no-op"
  end

  def test_incremental_detach
    # First detach: feat-b..feat-c range (includes feat-b at base)
    output, status = run_script("mad-detach", "feat-b", "feat-c", "--repo", @repo)
    assert status.success?, "First detach should succeed: #{output}"
    data = JSON.parse(File.read(@state_file))
    assert_equal 2, data["entries"].length
    branches = data["entries"].map { |e| e["branch"] }
    assert_includes branches, "feat-b"
    assert_includes branches, "feat-c"

    # Second detach: broader range, should add feat-a only (feat-b already detached)
    output, status = run_script("mad-detach", "main", "feat-b", "--repo", @repo)
    assert status.success?, "Second detach should succeed: #{output}"
    summary = JSON.parse(output)
    assert_equal 1, summary["detached"].length
    assert_equal "feat-a", summary["detached"][0]["branch"]

    data = JSON.parse(File.read(@state_file))
    assert_equal 3, data["entries"].length
    assert_equal [["feat-b", "feat-c"], ["main", "feat-b"]], data["ranges"]
  end

  def test_second_detach_skips_already_detached
    run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert status.success?
    summary = JSON.parse(output)
    assert_equal 0, summary["detached"].length
  end

  def test_dry_run_does_not_detach
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo, "--dry-run")
    assert status.success?

    %w[wt-feat-a wt-feat-b wt-feat-c].each do |wt|
      head = `git -C #{Shellwords.escape(File.join(@dir, wt))} symbolic-ref --short HEAD 2>&1`.strip
      refute head.empty?, "#{wt} should still be on a branch"
    end
    refute File.exist?(@state_file)
  end

  def test_rollback_on_failure
    # git log returns newest-first: E(feat-c), D(feat-b), C(feat-a)
    # So detach order is: feat-c, then feat-b, then feat-a.
    # Break feat-b so feat-c gets detached successfully, feat-b fails,
    # then feat-c should be rolled back.
    wt_b = File.join(@dir, "wt-feat-b")
    git_file = File.join(wt_b, ".git")

    git_content = File.read(git_file)
    File.delete(git_file)
    Dir.mkdir(git_file)

    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert_equal 1, status.exitstatus, "Expected exit 1 (rollback succeeded): #{output}"

    Dir.rmdir(git_file)
    File.write(git_file, git_content)

    branch_c = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-c"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-c", branch_c, "feat-c worktree should be restored by rollback"

    branch_a = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-a"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-a", branch_a, "feat-a was never detached, should still be on branch"

    refute File.exist?(@state_file), "State file should be deleted after rollback"
  end
end
