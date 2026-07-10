require "test_helper"
require "shellwords"

class MadBranchesTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = File.realpath(Dir.mktmpdir("mad-branches-test"))
    @repo = create_test_repo(@dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_finds_branches_in_range
    output, status = run_script("mad-branches", "main", "feat-c", "--repo", @repo)
    assert status.success?, "Expected success, got: #{output}"
    branches = JSON.parse(output)
    names = branches.map { |b| b["branch"] }
    assert_includes names, "feat-a"
    assert_includes names, "feat-b"
    assert_includes names, "feat-c"
    refute_includes names, "main"
  end

  def test_includes_worktree_paths
    output, status = run_script("mad-branches", "main", "feat-c", "--repo", @repo)
    branches = JSON.parse(output)
    feat_a = branches.find { |b| b["branch"] == "feat-a" }
    assert_equal File.join(@dir, "wt-feat-a"), feat_a["worktree"]
  end

  def test_null_worktree_for_branchless_worktree
    git(@repo, "branch", "no-wt-branch", "feat-a~1")
    output, _ = run_script("mad-branches", "main", "feat-c", "--repo", @repo)
    branches = JSON.parse(output)
    no_wt = branches.find { |b| b["branch"] == "no-wt-branch" }
    refute_nil no_wt
    assert_nil no_wt["worktree"]
  end

  def test_ancestor_validation_fails
    output, status, stderr = run_script("mad-branches", "feat-c", "main", "--repo", @repo)
    refute status.success?
    assert_match(/not an ancestor/i, stderr)
  end

  def test_multiple_branches_same_commit
    feat_a_sha = git(@repo, "rev-parse", "feat-a")
    git(@repo, "branch", "feat-a-alias", feat_a_sha)
    git(@repo, "worktree", "add", File.join(@dir, "wt-feat-a-alias"), "feat-a-alias")

    output, _ = run_script("mad-branches", "main", "feat-c", "--repo", @repo)
    branches = JSON.parse(output)
    names = branches.map { |b| b["branch"] }
    assert_includes names, "feat-a"
    assert_includes names, "feat-a-alias"
  end

  def test_defaults_to_cwd_repo
    Dir.chdir(@repo) do
      output, status = run_script("mad-branches", "main", "feat-c")
      assert status.success?, "Should succeed using cwd as repo: #{output}"
      branches = JSON.parse(output)
      refute_empty branches
    end
  end
end
