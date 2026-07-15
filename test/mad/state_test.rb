require "test_helper"
require "mad/state"

class Mad::StateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("mad-state-test")
    @state_file = File.join(@dir, "magit-auto-detach.json")
    @state = Mad::State.new(@state_file)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_exists_false_when_missing
    refute @state.exists?
  end

  def test_create_or_open_creates_new
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    assert @state.exists?
    data = @state.read
    assert_equal 2, data["version"]
    assert_equal [["main", "feat-c"]], data["ranges"]
    assert_equal [], data["entries"]
    assert data.key?("created_at")
  end

  def test_create_or_open_merges_into_existing
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.create_or_open(base_ref: "main", tip_ref: "feat-b")
    data = @state.read
    assert_equal [["main", "feat-c"], ["main", "feat-b"]], data["ranges"]
  end

  def test_create_or_open_deduplicates_ranges
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    data = @state.read
    assert_equal [["main", "feat-c"]], data["ranges"]
  end

  def test_append_entry
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    data = @state.read
    assert_equal 1, data["entries"].length
    assert_equal "/path/wt-a", data["entries"][0]["worktree"]
    assert_equal "feat-a", data["entries"][0]["branch"]
  end

  def test_append_multiple_entries
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    @state.append_entry(worktree: "/path/wt-b", branch: "feat-b")
    data = @state.read
    assert_equal 2, data["entries"].length
  end

  def test_remove_entry
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    @state.append_entry(worktree: "/path/wt-b", branch: "feat-b")
    @state.remove_entry("/path/wt-a")
    data = @state.read
    assert_equal 1, data["entries"].length
    assert_equal "/path/wt-b", data["entries"][0]["worktree"]
  end

  def test_read_raises_when_missing
    assert_raises(Mad::State::NotFoundError) do
      @state.read
    end
  end

  def test_delete
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.delete
    refute @state.exists?
  end

  def test_entries
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    entries = @state.entries
    assert_equal 1, entries.length
    assert_equal "feat-a", entries[0]["branch"]
  end

  def test_empty_check
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    assert @state.empty?
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    refute @state.empty?
  end

  def test_branches
    @state.create_or_open(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    @state.append_entry(worktree: "/path/wt-b", branch: "feat-b")
    branches = @state.branches
    assert_includes branches, "feat-a"
    assert_includes branches, "feat-b"
    assert_equal 2, branches.size
  end
end
