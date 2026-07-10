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

  def test_create
    @state.create(base_ref: "main", tip_ref: "feat-c")
    assert @state.exists?
    data = @state.read
    assert_equal 1, data["version"]
    assert_equal "main", data["base_ref"]
    assert_equal "feat-c", data["tip_ref"]
    assert_equal [], data["entries"]
    assert data.key?("created_at")
  end

  def test_create_refuses_if_exists
    @state.create(base_ref: "main", tip_ref: "feat-c")
    assert_raises(Mad::State::AlreadyExistsError) do
      @state.create(base_ref: "main", tip_ref: "feat-c")
    end
  end

  def test_append_entry
    @state.create(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    data = @state.read
    assert_equal 1, data["entries"].length
    assert_equal "/path/wt-a", data["entries"][0]["worktree"]
    assert_equal "feat-a", data["entries"][0]["branch"]
  end

  def test_append_multiple_entries
    @state.create(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    @state.append_entry(worktree: "/path/wt-b", branch: "feat-b")
    data = @state.read
    assert_equal 2, data["entries"].length
  end

  def test_remove_entry
    @state.create(base_ref: "main", tip_ref: "feat-c")
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
    @state.create(base_ref: "main", tip_ref: "feat-c")
    @state.delete
    refute @state.exists?
  end

  def test_entries
    @state.create(base_ref: "main", tip_ref: "feat-c")
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    entries = @state.entries
    assert_equal 1, entries.length
    assert_equal "feat-a", entries[0]["branch"]
  end

  def test_empty_check
    @state.create(base_ref: "main", tip_ref: "feat-c")
    assert @state.empty?
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    refute @state.empty?
  end
end
