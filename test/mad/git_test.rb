require "test_helper"
require "shellwords"
require "mad/git"

class Mad::GitTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = File.realpath(Dir.mktmpdir("mad-git-test"))
    @repo = create_test_repo(@dir)
    @git = Mad::Git.new(@repo)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_toplevel
    assert_equal @repo, @git.toplevel
  end

  def test_common_dir
    common = @git.common_dir
    assert common.end_with?(".git"), "Expected .git dir, got: #{common}"
  end

  def test_ancestor_check_true
    main_sha = @git.rev_parse("main")
    feat_c_sha = @git.rev_parse("feat-c")
    assert @git.ancestor?(main_sha, feat_c_sha)
  end

  def test_ancestor_check_false
    main_sha = @git.rev_parse("main")
    feat_c_sha = @git.rev_parse("feat-c")
    refute @git.ancestor?(feat_c_sha, main_sha)
  end

  def test_commits_in_range
    commits = @git.commits_in_range("main", "feat-c")
    assert_equal 5, commits.length
  end

  def test_branches_at
    feat_a_sha = @git.rev_parse("feat-a")
    branches = @git.branches_at(feat_a_sha)
    assert_includes branches, "feat-a"
  end

  def test_worktree_branches
    mapping = @git.worktree_branches
    assert_equal File.join(@dir, "wt-feat-a"), mapping["feat-a"]
    assert_equal File.join(@dir, "wt-feat-b"), mapping["feat-b"]
    assert_equal File.join(@dir, "wt-feat-c"), mapping["feat-c"]
  end

  def test_checkout_detach
    wt = File.join(@dir, "wt-feat-a")
    @git.checkout_detach(wt)
    head = `git -C #{Shellwords.escape(wt)} symbolic-ref HEAD 2>&1`
    refute $?.success?, "HEAD should be detached"
  end

  def test_checkout_branch
    wt = File.join(@dir, "wt-feat-a")
    @git.checkout_detach(wt)
    @git.checkout_branch(wt, "feat-a")
    branch = `git -C #{Shellwords.escape(wt)} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-a", branch
  end

  def test_rev_parse
    sha = @git.rev_parse("main")
    assert_match(/\A[0-9a-f]{40}\z/, sha)
  end
end
