# Magit Auto-Detach Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tool that auto-detaches git worktrees for branch stack rebases and restores them on command, integrated with magit.

**Architecture:** Elisp thin layer calls Ruby scripts via `call-process`. Ruby handles git operations (find branches, detach, restore) and state persistence (JSON in `.git/`). ERT tests cover both Ruby scripts (via shell-command) and elisp integration.

**Tech Stack:** Ruby (scripts), Emacs Lisp (magit integration), ERT (tests), JSON (state)

**Spec:** `docs/superpowers/specs/2026-07-10-magit-auto-detach-design.md`

**Deployment paths:**
- Ruby scripts: `~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/`
- Elisp: `~/ghq/github.com/dcluna/dotfiles/elisp/magit-auto-detach.el`
- Tests + test repo: `/Users/danielluna/Projects/magit-auto-detach/`

---

## File Structure

### Ruby scripts (`~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/`)

| File | Responsibility |
|------|---------------|
| `lib/mad/git.rb` | Git command wrappers: log, branch, worktree list, checkout, merge-base |
| `lib/mad/state.rb` | State file CRUD: create, read, append entry, remove entry, delete |
| `mad-branches` | Executable: find branches in ref range, output JSON |
| `mad-detach` | Executable: detach worktrees, write state, rollback on failure |
| `mad-restore` | Executable: restore worktrees, update state incrementally |

### Elisp (`~/ghq/github.com/dcluna/dotfiles/elisp/`)

| File | Responsibility |
|------|---------------|
| `magit-auto-detach.el` | Interactive commands, magit transient integration, script invocation |

### Tests (`/Users/danielluna/Projects/magit-auto-detach/`)

| File | Responsibility |
|------|---------------|
| `test/test_helper.rb` | Shared fixture: create/destroy test repo with branches and worktrees |
| `test/mad/git_test.rb` | Unit tests for `Mad::Git` |
| `test/mad/state_test.rb` | Unit tests for `Mad::State` |
| `test/mad_branches_test.rb` | Integration tests for `mad-branches` script |
| `test/mad_detach_test.rb` | Integration tests for `mad-detach` script (happy + failure + rollback) |
| `test/mad_restore_test.rb` | Integration tests for `mad-restore` script (happy + failure + partial) |
| `test/magit-auto-detach-test.el` | ERT tests for elisp layer |

---

## Chunk 1: Ruby Library Layer

### Task 1: Project scaffolding

**Files:**
- Create: `/Users/danielluna/Projects/magit-auto-detach/Gemfile`
- Create: `/Users/danielluna/Projects/magit-auto-detach/Rakefile`
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/test_helper.rb`

- [ ] **Step 1: Create Gemfile with minitest**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/Gemfile
source "https://rubygems.org"

gem "minitest", "~> 5.0"
gem "rake"
```

- [ ] **Step 2: Create Rakefile**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/Rakefile
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << File.expand_path("~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach")
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test
```

- [ ] **Step 3: Create test_helper with repo fixture**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/test/test_helper.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require "shellwords"

$LOAD_PATH.unshift(File.expand_path("~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/lib"))

BIN_DIR = File.expand_path("~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach")

module RepoFixture
  # Creates a test repo with linear history and worktrees:
  #   commits: A <- B <- C <- D <- E
  #   branches: main=A, feat-a=C, feat-b=D, feat-c=E
  #   worktrees: wt-feat-a (feat-a), wt-feat-b (feat-b), wt-feat-c (feat-c)
  def create_test_repo(dir)
    repo = File.join(dir, "repo")
    FileUtils.mkdir_p(repo)

    git(repo, "init", "-b", "main")
    git(repo, "config", "user.email", "test@test.com")
    git(repo, "config", "user.name", "Test")

    # Commit A (main stays here)
    File.write(File.join(repo, "a.txt"), "a")
    git(repo, "add", "a.txt")
    git(repo, "commit", "-m", "A")

    # Commit B (no branch)
    File.write(File.join(repo, "b.txt"), "b")
    git(repo, "add", "b.txt")
    git(repo, "commit", "-m", "B")

    # Commit C -> feat-a
    File.write(File.join(repo, "c.txt"), "c")
    git(repo, "add", "c.txt")
    git(repo, "commit", "-m", "C")
    git(repo, "branch", "feat-a")

    # Commit D -> feat-b
    File.write(File.join(repo, "d.txt"), "d")
    git(repo, "add", "d.txt")
    git(repo, "commit", "-m", "D")
    git(repo, "branch", "feat-b")

    # Commit E -> feat-c (HEAD stays here)
    File.write(File.join(repo, "e.txt"), "e")
    git(repo, "add", "e.txt")
    git(repo, "commit", "-m", "E")
    git(repo, "branch", "feat-c")

    # Create worktrees
    git(repo, "worktree", "add", File.join(dir, "wt-feat-a"), "feat-a")
    git(repo, "worktree", "add", File.join(dir, "wt-feat-b"), "feat-b")
    git(repo, "worktree", "add", File.join(dir, "wt-feat-c"), "feat-c")

    # Detach main repo HEAD so it's not on feat-c
    git(repo, "checkout", "--detach")

    repo
  end

  def git(repo, *args)
    out = `git -C #{Shellwords.escape(repo)} #{args.map { |a| Shellwords.escape(a) }.join(" ")} 2>&1`
    raise "git #{args.first} failed: #{out}" unless $?.success?
    out.strip
  end

  def git_common_dir(repo)
    `git -C #{Shellwords.escape(repo)} rev-parse --git-common-dir 2>&1`.strip
  end

  def run_script(name, *args)
    require "open3"
    cmd_args = [File.join(BIN_DIR, name)] + args
    stdout, stderr, status = Open3.capture3("ruby", *cmd_args)
    [stdout, status, stderr]
  end
end
```

- [ ] **Step 4: Run bundle install**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle install`

- [ ] **Step 5: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach
git add Gemfile Gemfile.lock Rakefile test/test_helper.rb
git commit -m "Add project scaffolding with minitest and repo fixture helper"
```

### Task 2: `Mad::Git` — git command wrappers

**Files:**
- Create: `~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/lib/mad/git.rb`
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/mad/git_test.rb`

- [ ] **Step 1: Write failing tests for `Mad::Git`**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/test/mad/git_test.rb
require "test_helper"
require "shellwords"
require "mad/git"

class Mad::GitTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = Dir.mktmpdir("mad-git-test")
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
    # Should be B, C, D, E (4 commits after A)
    assert_equal 4, commits.length
  end

  def test_branches_at
    feat_a_sha = @git.rev_parse("feat-a")
    branches = @git.branches_at(feat_a_sha)
    assert_includes branches, "feat-a"
  end

  def test_worktree_branches
    mapping = @git.worktree_branches
    # mapping: { "feat-a" => "/path/wt-feat-a", "feat-b" => ... }
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test`
Expected: NameError — `Mad::Git` not defined

- [ ] **Step 3: Implement `Mad::Git`**

```ruby
# ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/lib/mad/git.rb
require "open3"
require "shellwords"

module Mad
  class Git
    class CommandError < StandardError; end

    def initialize(repo_path)
      @repo = repo_path
    end

    def toplevel
      run("rev-parse", "--show-toplevel")
    end

    def common_dir
      path = run("rev-parse", "--git-common-dir")
      File.expand_path(path, @repo)
    end

    def rev_parse(ref)
      run("rev-parse", ref)
    end

    def ancestor?(base_sha, tip_sha)
      _, status = Open3.capture2e("git", "-C", @repo, "merge-base", "--is-ancestor", base_sha, tip_sha)
      status.success?
    end

    def commits_in_range(base, tip)
      output = run("log", "--first-parent", "--format=%H", "#{base}..#{tip}")
      output.split("\n").reject(&:empty?)
    end

    def branches_at(sha)
      output = run("branch", "--points-at", sha, "--format=%(refname:short)")
      output.split("\n").reject(&:empty?)
    end

    def worktree_branches
      output = run("worktree", "list", "--porcelain")
      mapping = {}
      current_path = nil

      output.each_line do |line|
        line = line.chomp
        if line.start_with?("worktree ")
          current_path = line.sub("worktree ", "")
        elsif line.start_with?("branch refs/heads/")
          branch = line.sub("branch refs/heads/", "")
          mapping[branch] = current_path
        elsif line.empty?
          current_path = nil
        end
      end

      mapping
    end

    def checkout_detach(worktree_path)
      run_in(worktree_path, "checkout", "--detach")
    end

    def checkout_branch(worktree_path, branch)
      run_in(worktree_path, "checkout", branch)
    end

    private

    def run(*args)
      stdout, stderr, status = Open3.capture3("git", "-C", @repo, *args)
      raise CommandError, "git #{args.first} failed: #{stderr}" unless status.success?
      stdout.strip
    end

    def run_in(path, *args)
      stdout, stderr, status = Open3.capture3("git", "-C", path, *args)
      raise CommandError, "git #{args.first} in #{path} failed: #{stderr}" unless status.success?
      stdout.strip
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test`
Expected: All tests in `git_test.rb` PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && git add test/mad/git_test.rb
cd ~/ghq/github.com/dcluna/dotfiles && git add bin/magit-auto-detach/lib/mad/git.rb
# Commit in both repos
cd /Users/danielluna/Projects/magit-auto-detach && git commit -m "Add Mad::Git with unit tests"
cd ~/ghq/github.com/dcluna/dotfiles && git commit -m "Add Mad::Git — git command wrappers for magit-auto-detach"
```

### Task 3: `Mad::State` — state file management

**Files:**
- Create: `~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/lib/mad/state.rb`
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/mad/state_test.rb`

- [ ] **Step 1: Write failing tests for `Mad::State`**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/test/mad/state_test.rb
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

  def test_empty?
    @state.create(base_ref: "main", tip_ref: "feat-c")
    assert @state.empty?
    @state.append_entry(worktree: "/path/wt-a", branch: "feat-a")
    refute @state.empty?
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad/state_test.rb`
Expected: LoadError — `mad/state` not found

- [ ] **Step 3: Implement `Mad::State`**

```ruby
# ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/lib/mad/state.rb
require "json"
require "time"

module Mad
  class State
    class AlreadyExistsError < StandardError; end
    class NotFoundError < StandardError; end

    STATE_VERSION = 1

    def initialize(path)
      @path = path
    end

    def exists?
      File.exist?(@path)
    end

    def create(base_ref:, tip_ref:)
      raise AlreadyExistsError, "State file already exists: #{@path}" if exists?

      data = {
        "version" => STATE_VERSION,
        "created_at" => Time.now.utc.iso8601,
        "base_ref" => base_ref,
        "tip_ref" => tip_ref,
        "entries" => []
      }
      write_data(data)
    end

    def read
      raise NotFoundError, "No state file at: #{@path}" unless exists?
      JSON.parse(File.read(@path))
    end

    def append_entry(worktree:, branch:)
      data = read
      data["entries"] << { "worktree" => worktree, "branch" => branch }
      write_data(data)
    end

    def remove_entry(worktree_path)
      data = read
      data["entries"].reject! { |e| e["worktree"] == worktree_path }
      write_data(data)
    end

    def entries
      read["entries"]
    end

    def empty?
      entries.empty?
    end

    def delete
      File.delete(@path) if exists?
    end

    private

    def write_data(data)
      File.write(@path, JSON.pretty_generate(data) + "\n")
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad/state_test.rb`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && git add test/mad/state_test.rb
cd ~/ghq/github.com/dcluna/dotfiles && git add bin/magit-auto-detach/lib/mad/state.rb
cd /Users/danielluna/Projects/magit-auto-detach && git commit -m "Add Mad::State with unit tests"
cd ~/ghq/github.com/dcluna/dotfiles && git commit -m "Add Mad::State — JSON state file management for magit-auto-detach"
```

---

## Chunk 2: Ruby Executable Scripts

### Task 4: `mad-branches` script

**Files:**
- Create: `~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-branches`
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/mad_branches_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/test/mad_branches_test.rb
require "test_helper"
require "shellwords"

class MadBranchesTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = Dir.mktmpdir("mad-branches-test")
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
    # Create a branch at commit B with no worktree
    git(@repo, "branch", "no-wt-branch", "feat-a~1")
    output, _ = run_script("mad-branches", "main", "feat-c", "--repo", @repo)
    branches = JSON.parse(output)
    no_wt = branches.find { |b| b["branch"] == "no-wt-branch" }
    refute_nil no_wt
    assert_nil no_wt["worktree"]
  end

  def test_ancestor_validation_fails
    output, status = run_script("mad-branches", "feat-c", "main", "--repo", @repo)
    refute status.success?
    assert_match(/not an ancestor/i, output)
  end

  def test_multiple_branches_same_commit
    # Point another branch at feat-a's commit
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad_branches_test.rb`
Expected: Errno::ENOENT — `mad-branches` script not found

- [ ] **Step 3: Implement `mad-branches`**

```ruby
#!/usr/bin/env ruby
# ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-branches
require_relative "lib/mad/git"
require "json"
require "optparse"
require "set"

repo = nil
OptionParser.new do |opts|
  opts.banner = "Usage: mad-branches <base-ref> <tip-ref> [--repo <path>]"
  opts.on("--repo PATH", "Repository path") { |v| repo = v }
end.parse!

base_ref, tip_ref = ARGV.shift(2)
abort "Usage: mad-branches <base-ref> <tip-ref> [--repo <path>]" unless base_ref && tip_ref

repo ||= `git rev-parse --show-toplevel 2>/dev/null`.strip
abort "Not in a git repository" if repo.empty?

git = Mad::Git.new(repo)

unless git.ancestor?(git.rev_parse(base_ref), git.rev_parse(tip_ref))
  $stderr.puts "Error: #{base_ref} is not an ancestor of #{tip_ref}"
  exit 1
end

commits = git.commits_in_range(base_ref, tip_ref)
worktree_map = git.worktree_branches

results = []
seen_branches = Set.new

commits.each do |sha|
  git.branches_at(sha).each do |branch|
    next if seen_branches.include?(branch)
    seen_branches.add(branch)
    results << {
      "branch" => branch,
      "sha" => sha,
      "worktree" => worktree_map[branch]
    }
  end
end

puts JSON.pretty_generate(results)
```

- [ ] **Step 4: Make script executable**

Run: `chmod +x ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-branches`

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad_branches_test.rb`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && git add test/mad_branches_test.rb
cd ~/ghq/github.com/dcluna/dotfiles && git add bin/magit-auto-detach/mad-branches
cd /Users/danielluna/Projects/magit-auto-detach && git commit -m "Add mad-branches integration tests"
cd ~/ghq/github.com/dcluna/dotfiles && git commit -m "Add mad-branches — find branches in ref range for magit-auto-detach"
```

### Task 5: `mad-detach` script

**Files:**
- Create: `~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-detach`
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/mad_detach_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/test/mad_detach_test.rb
require "test_helper"
require "shellwords"
require "mad/state"

class MadDetachTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = Dir.mktmpdir("mad-detach-test")
    @repo = create_test_repo(@dir)
    @state_file = File.join(git_common_dir(@repo), "magit-auto-detach.json")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- Happy path ---

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
    assert_equal 1, data["version"]
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

  # --- No worktrees in range ---

  def test_no_worktrees_noop
    # Remove all worktrees first
    %w[feat-a feat-b feat-c].each do |branch|
      git(@repo, "worktree", "remove", File.join(@dir, "wt-#{branch}"))
    end
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert status.success?
    refute File.exist?(@state_file), "No state file for no-op"
  end

  # --- Refuses if state file exists ---

  def test_refuses_with_existing_state
    run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    refute status.success?
    assert_match(/already exists|previous session/i, output)
  end

  # --- Dry run ---

  def test_dry_run_does_not_detach
    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo, "--dry-run")
    assert status.success?

    # Worktrees still on branches
    %w[wt-feat-a wt-feat-b wt-feat-c].each do |wt|
      head = `git -C #{Shellwords.escape(File.join(@dir, wt))} symbolic-ref --short HEAD 2>&1`.strip
      refute head.empty?, "#{wt} should still be on a branch"
    end
    refute File.exist?(@state_file)
  end

  # --- Detach failure with rollback ---

  def test_rollback_on_failure
    # git log returns newest-first: E(feat-c), D(feat-b), C(feat-a)
    # So detach order is: feat-c, then feat-b, then feat-a.
    # Break feat-b so feat-c gets detached successfully, feat-b fails,
    # then feat-c should be rolled back.
    wt_b = File.join(@dir, "wt-feat-b")
    git_file = File.join(wt_b, ".git")

    # Replace .git file with a directory (breaks git operations)
    git_content = File.read(git_file)
    File.delete(git_file)
    Dir.mkdir(git_file)

    output, status = run_script("mad-detach", "main", "feat-c", "--repo", @repo)
    assert_equal 1, status.exitstatus, "Expected exit 1 (rollback succeeded): #{output}"

    # Restore .git file so we can inspect state
    Dir.rmdir(git_file)
    File.write(git_file, git_content)

    # feat-c WAS detached before feat-b failed — verify it got rolled back
    branch_c = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-c"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-c", branch_c, "feat-c worktree should be restored by rollback"

    # feat-a was never detached (comes after feat-b in order), should still be on branch
    branch_a = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-a"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-a", branch_a, "feat-a was never detached, should still be on branch"

    # State file should be cleaned up
    refute File.exist?(@state_file), "State file should be deleted after rollback"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad_detach_test.rb`
Expected: Errno::ENOENT — `mad-detach` not found

- [ ] **Step 3: Implement `mad-detach`**

```ruby
#!/usr/bin/env ruby
# ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-detach
require_relative "lib/mad/git"
require_relative "lib/mad/state"
require "json"
require "optparse"
require "set"

repo = nil
dry_run = false
OptionParser.new do |opts|
  opts.banner = "Usage: mad-detach <base-ref> <tip-ref> [--repo <path>] [--dry-run]"
  opts.on("--repo PATH", "Repository path") { |v| repo = v }
  opts.on("--dry-run", "Show what would be detached") { dry_run = true }
end.parse!

base_ref, tip_ref = ARGV.shift(2)
abort "Usage: mad-detach <base-ref> <tip-ref> [--repo <path>] [--dry-run]" unless base_ref && tip_ref

repo ||= `git rev-parse --show-toplevel 2>/dev/null`.strip
abort "Not in a git repository" if repo.empty?

git = Mad::Git.new(repo)

unless git.ancestor?(git.rev_parse(base_ref), git.rev_parse(tip_ref))
  $stderr.puts "Error: #{base_ref} is not an ancestor of #{tip_ref}"
  exit 1
end

state_path = File.join(git.common_dir, "magit-auto-detach.json")
state = Mad::State.new(state_path)

if state.exists?
  $stderr.puts "Error: Previous detach session not restored. Run mad-restore first."
  $stderr.puts "State file: #{state_path}"
  exit 1
end

# Find branches with worktrees in range
commits = git.commits_in_range(base_ref, tip_ref)
worktree_map = git.worktree_branches
seen = Set.new
to_detach = []

commits.each do |sha|
  git.branches_at(sha).each do |branch|
    next if seen.include?(branch)
    seen.add(branch)
    wt = worktree_map[branch]
    to_detach << { "branch" => branch, "sha" => sha, "worktree" => wt } if wt
  end
end

if to_detach.empty?
  puts JSON.pretty_generate({ "detached" => [], "message" => "No worktrees to detach" })
  exit 0
end

if dry_run
  puts JSON.pretty_generate({ "would_detach" => to_detach })
  exit 0
end

# Create state file and detach
state.create(base_ref: base_ref, tip_ref: tip_ref)
detached = []

begin
  to_detach.each do |entry|
    git.checkout_detach(entry["worktree"])
    state.append_entry(worktree: entry["worktree"], branch: entry["branch"])
    detached << entry
  end
rescue Mad::Git::CommandError => e
  $stderr.puts "Error detaching: #{e.message}"
  $stderr.puts "Rolling back #{detached.length} detached worktree(s)..."

  rollback_failures = []
  state.entries.each do |st_entry|
    begin
      git.checkout_branch(st_entry["worktree"], st_entry["branch"])
    rescue Mad::Git::CommandError => re
      rollback_failures << { "worktree" => st_entry["worktree"], "error" => re.message }
    end
  end

  state.delete

  if rollback_failures.any?
    $stderr.puts "Rollback failures:"
    rollback_failures.each { |f| $stderr.puts "  #{f['worktree']}: #{f['error']}" }
    exit 2
  else
    $stderr.puts "Rollback successful."
    exit 1
  end
end

puts JSON.pretty_generate({ "detached" => detached })
```

- [ ] **Step 4: Make executable**

Run: `chmod +x ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-detach`

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad_detach_test.rb`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && git add test/mad_detach_test.rb
cd ~/ghq/github.com/dcluna/dotfiles && git add bin/magit-auto-detach/mad-detach
cd /Users/danielluna/Projects/magit-auto-detach && git commit -m "Add mad-detach integration tests"
cd ~/ghq/github.com/dcluna/dotfiles && git commit -m "Add mad-detach — detach worktrees with state tracking and rollback"
```

### Task 6: `mad-restore` script

**Files:**
- Create: `~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-restore`
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/mad_restore_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# /Users/danielluna/Projects/magit-auto-detach/test/mad_restore_test.rb
require "test_helper"
require "shellwords"
require "mad/state"

class MadRestoreTest < Minitest::Test
  include RepoFixture

  def setup
    @dir = Dir.mktmpdir("mad-restore-test")
    @repo = create_test_repo(@dir)
    @state_file = File.join(git_common_dir(@repo), "magit-auto-detach.json")
    # Detach first so we have something to restore
    run_script("mad-detach", "main", "feat-c", "--repo", @repo)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- Happy path ---

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

  # --- No state file ---

  def test_no_state_file_message
    File.delete(@state_file)
    output, status = run_script("mad-restore", "--repo", @repo)
    assert status.success?
    assert_match(/nothing to restore/i, output)
  end

  # --- Partial restore (branch deleted) ---

  def test_partial_restore_on_failure
    # Delete feat-b branch so restore will fail for it
    # First we need to find feat-b's SHA to delete the branch
    # Since feat-b's worktree is detached, we can delete the branch
    git(@repo, "branch", "-D", "feat-b")

    output, status = run_script("mad-restore", "--repo", @repo)
    assert_equal 1, status.exitstatus, "Expected exit 1 for partial restore"

    # feat-a and feat-c should be restored
    branch_a = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-a"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-a", branch_a

    branch_c = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-c"))} symbolic-ref --short HEAD 2>&1`.strip
    assert_equal "feat-c", branch_c

    # State file should only have feat-b entry
    assert File.exist?(@state_file)
    data = JSON.parse(File.read(@state_file))
    assert_equal 1, data["entries"].length
    assert_equal "feat-b", data["entries"][0]["branch"]
  end

  # --- Dry run ---

  def test_dry_run
    output, status = run_script("mad-restore", "--repo", @repo, "--dry-run")
    assert status.success?
    # Worktrees still detached
    head = `git -C #{Shellwords.escape(File.join(@dir, "wt-feat-a"))} symbolic-ref HEAD 2>&1`
    refute $?.success?, "Should still be detached"
    # State file still present
    assert File.exist?(@state_file)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad_restore_test.rb`
Expected: Errno::ENOENT — `mad-restore` not found

- [ ] **Step 3: Implement `mad-restore`**

```ruby
#!/usr/bin/env ruby
# ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-restore
require_relative "lib/mad/git"
require_relative "lib/mad/state"
require "json"
require "optparse"

repo = nil
dry_run = false
OptionParser.new do |opts|
  opts.banner = "Usage: mad-restore [--repo <path>] [--dry-run]"
  opts.on("--repo PATH", "Repository path") { |v| repo = v }
  opts.on("--dry-run", "Show what would be restored") { dry_run = true }
end.parse!

repo ||= `git rev-parse --show-toplevel 2>/dev/null`.strip
abort "Not in a git repository" if repo.empty?

git = Mad::Git.new(repo)
state_path = File.join(git.common_dir, "magit-auto-detach.json")
state = Mad::State.new(state_path)

unless state.exists?
  puts JSON.pretty_generate({ "message" => "Nothing to restore" })
  exit 0
end

entries = state.entries

if dry_run
  puts JSON.pretty_generate({ "would_restore" => entries })
  exit 0
end

restored = []
failures = []

entries.each do |entry|
  begin
    git.checkout_branch(entry["worktree"], entry["branch"])
    state.remove_entry(entry["worktree"])
    restored << entry
  rescue Mad::Git::CommandError => e
    failures << { "worktree" => entry["worktree"], "branch" => entry["branch"], "error" => e.message }
    $stderr.puts "Failed to restore #{entry['worktree']}: #{e.message}"
  end
end

state.delete if state.exists? && state.empty?

result = { "restored" => restored }
result["failures"] = failures if failures.any?
puts JSON.pretty_generate(result)

exit(failures.any? ? 1 : 0)
```

- [ ] **Step 4: Make executable**

Run: `chmod +x ~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-restore`

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test TEST=test/mad_restore_test.rb`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && git add test/mad_restore_test.rb
cd ~/ghq/github.com/dcluna/dotfiles && git add bin/magit-auto-detach/mad-restore
cd /Users/danielluna/Projects/magit-auto-detach && git commit -m "Add mad-restore integration tests"
cd ~/ghq/github.com/dcluna/dotfiles && git commit -m "Add mad-restore — restore detached worktrees from state file"
```

---

## Chunk 3: Elisp Layer + ERT Tests

### Task 7: `magit-auto-detach.el`

**Files:**
- Create: `~/ghq/github.com/dcluna/dotfiles/elisp/magit-auto-detach.el`

- [ ] **Step 1: Implement the elisp package**

```elisp
;;; magit-auto-detach.el --- Auto-detach/restore worktrees for branch stack rebases -*- lexical-binding: t; -*-

;;; Commentary:
;; Detaches git worktrees checked out on branches within a ref range
;; so you can rebase a branch stack with --update-refs, then restores them.

;;; Code:

(require 'magit)
(require 'json)

(defgroup magit-auto-detach nil
  "Auto-detach and restore git worktrees for rebasing branch stacks."
  :group 'magit)

(defcustom magit-auto-detach-bin-directory
  (expand-file-name "../bin/magit-auto-detach"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing mad-* Ruby scripts."
  :type 'directory
  :group 'magit-auto-detach)

(defun magit-auto-detach--script (name)
  "Return full path to script NAME."
  (expand-file-name name magit-auto-detach-bin-directory))

(defun magit-auto-detach--run (script &rest args)
  "Run SCRIPT with ARGS, return (exit-code stdout stderr)."
  (let ((cmd (magit-auto-detach--script script))
        (repo (magit-toplevel)))
    (unless repo
      (user-error "Not in a git repository"))
    (with-temp-buffer
      (let* ((err-file (make-temp-file "mad-stderr"))
             (full-args (append (list cmd) args (list "--repo" repo)))
             (exit-code (apply #'call-process "ruby" nil
                               (list (current-buffer) err-file) nil
                               full-args))
             (stdout (buffer-string))
             (stderr (with-temp-buffer
                       (insert-file-contents err-file)
                       (prog1 (buffer-string)
                         (delete-file err-file)))))
        (list exit-code stdout stderr)))))

(defun magit-auto-detach--parse-json (str)
  "Parse JSON string STR, return nil on empty/invalid input."
  (when (and str (not (string-empty-p (string-trim str))))
    (json-parse-string str :object-type 'alist)))

;;;###autoload
(defun magit-auto-detach-detach (base-ref tip-ref)
  "Detach worktrees for branches in BASE-REF..TIP-REF range.
Uses `magit-read-branch-or-commit' for ref selection."
  (interactive
   (list (magit-read-branch-or-commit "Base ref (ancestor)")
         (magit-read-branch-or-commit "Tip ref"
                                      (magit-get-current-branch))))
  (pcase-let ((`(,code ,stdout ,stderr) (magit-auto-detach--run "mad-detach" base-ref tip-ref)))
    (cond
     ((= code 0)
      (let* ((result (magit-auto-detach--parse-json stdout))
             (detached (alist-get 'detached result))
             (count (length detached)))
        (if (= count 0)
            (message "No worktrees to detach in %s..%s" base-ref tip-ref)
          (message "Detached %d worktree(s) in %s..%s" count base-ref tip-ref))
        (magit-refresh)))
     ((= code 1)
      (user-error "Detach failed (rollback succeeded): %s" (string-trim stderr)))
     ((= code 2)
      (user-error "Detach failed (rollback ALSO failed): %s" (string-trim stderr)))
     (t
      (user-error "mad-detach exited %d: %s" code (string-trim stderr))))))

;;;###autoload
(defun magit-auto-detach-restore ()
  "Restore previously detached worktrees to their original branches."
  (interactive)
  (pcase-let ((`(,code ,stdout ,stderr) (magit-auto-detach--run "mad-restore")))
    (cond
     ((= code 0)
      (let* ((result (magit-auto-detach--parse-json stdout))
             (msg (alist-get 'message result))
             (restored (alist-get 'restored result)))
        (if msg
            (message "%s" msg)
          (message "Restored %d worktree(s)" (length restored)))
        (magit-refresh)))
     ((= code 1)
      (let* ((result (magit-auto-detach--parse-json stdout))
             (restored (length (alist-get 'restored result)))
             (failures (length (alist-get 'failures result))))
        (user-error "Partial restore: %d restored, %d failed. See mad-restore output. %s"
                    restored failures (string-trim stderr))))
     (t
      (user-error "mad-restore exited %d: %s" code (string-trim stderr))))))

;;;###autoload
(defun magit-auto-detach-status ()
  "Show status of currently detached worktrees."
  (interactive)
  (let* ((repo (or (magit-toplevel)
                   (user-error "Not in a git repository")))
         (common-dir (string-trim
                      (shell-command-to-string
                       (format "git -C %s rev-parse --git-common-dir"
                               (shell-quote-argument repo)))))
         (state-file (expand-file-name "magit-auto-detach.json" common-dir)))
    (if (not (file-exists-p state-file))
        (message "No active detach session")
      (let* ((data (json-parse-string
                    (with-temp-buffer
                      (insert-file-contents state-file)
                      (buffer-string))
                    :object-type 'alist))
             (entries (alist-get 'entries data))
             (base (alist-get 'base_ref data))
             (tip (alist-get 'tip_ref data)))
        (message "Detach session: %s..%s (%d worktree(s))\n%s"
                 base tip (length entries)
                 (mapconcat (lambda (e)
                              (format "  %s → %s"
                                      (alist-get 'worktree e)
                                      (alist-get 'branch e)))
                            entries "\n"))))))

;; Magit transient integration
(with-eval-after-load 'magit
  (ignore-errors
    (transient-append-suffix 'magit-worktree '(-1)
      '("d" "Detach for rebase" magit-auto-detach-detach))
    (transient-append-suffix 'magit-worktree '(-1)
      '("r" "Restore detached" magit-auto-detach-restore))
    (transient-append-suffix 'magit-worktree '(-1)
      '("s" "Detach status" magit-auto-detach-status))))

(provide 'magit-auto-detach)
;;; magit-auto-detach.el ends here
```

- [ ] **Step 2: Commit**

```bash
cd ~/ghq/github.com/dcluna/dotfiles && git add elisp/magit-auto-detach.el
git commit -m "Add magit-auto-detach.el — magit UI for worktree detach/restore"
```

### Task 8: ERT tests

**Files:**
- Create: `/Users/danielluna/Projects/magit-auto-detach/test/magit-auto-detach-test.el`

- [ ] **Step 1: Write ERT tests**

```elisp
;;; magit-auto-detach-test.el --- ERT tests for magit-auto-detach -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)

;; Load the package under test
(load (expand-file-name "~/ghq/github.com/dcluna/dotfiles/elisp/magit-auto-detach.el"))

(defvar mad-test--bin-dir
  (expand-file-name "~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach"))

(defun mad-test--create-repo (dir)
  "Create test repo in DIR with branches and worktrees.
Returns the repo path."
  (let ((repo (expand-file-name "repo" dir)))
    (make-directory repo t)
    (mad-test--git repo "init" "-b" "main")
    (mad-test--git repo "config" "user.email" "test@test.com")
    (mad-test--git repo "config" "user.name" "Test")
    ;; A
    (with-temp-file (expand-file-name "a.txt" repo) (insert "a"))
    (mad-test--git repo "add" "a.txt")
    (mad-test--git repo "commit" "-m" "A")
    ;; B
    (with-temp-file (expand-file-name "b.txt" repo) (insert "b"))
    (mad-test--git repo "add" "b.txt")
    (mad-test--git repo "commit" "-m" "B")
    ;; C -> feat-a
    (with-temp-file (expand-file-name "c.txt" repo) (insert "c"))
    (mad-test--git repo "add" "c.txt")
    (mad-test--git repo "commit" "-m" "C")
    (mad-test--git repo "branch" "feat-a")
    ;; D -> feat-b
    (with-temp-file (expand-file-name "d.txt" repo) (insert "d"))
    (mad-test--git repo "add" "d.txt")
    (mad-test--git repo "commit" "-m" "D")
    (mad-test--git repo "branch" "feat-b")
    ;; E -> feat-c
    (with-temp-file (expand-file-name "e.txt" repo) (insert "e"))
    (mad-test--git repo "add" "e.txt")
    (mad-test--git repo "commit" "-m" "E")
    (mad-test--git repo "branch" "feat-c")
    ;; Worktrees
    (mad-test--git repo "worktree" "add" (expand-file-name "wt-feat-a" dir) "feat-a")
    (mad-test--git repo "worktree" "add" (expand-file-name "wt-feat-b" dir) "feat-b")
    (mad-test--git repo "worktree" "add" (expand-file-name "wt-feat-c" dir) "feat-c")
    ;; Detach main repo
    (mad-test--git repo "checkout" "--detach")
    repo))

(defun mad-test--git (repo &rest args)
  "Run git in REPO with ARGS."
  (let ((default-directory repo))
    (with-temp-buffer
      (let ((exit-code (apply #'call-process "git" nil t nil "-C" repo args)))
        (unless (= exit-code 0)
          (error "git %s failed: %s" (car args) (buffer-string)))
        (string-trim (buffer-string))))))

(defun mad-test--run-script (name dir &rest args)
  "Run mad script NAME with --repo DIR and extra ARGS.
Returns (exit-code stdout stderr)."
  (with-temp-buffer
    (let* ((err-file (make-temp-file "mad-test-stderr"))
           (cmd (expand-file-name name mad-test--bin-dir))
           (full-args (append args (list "--repo" dir)))
           (exit-code (apply #'call-process "ruby" nil
                             (list (current-buffer) err-file) nil
                             cmd full-args))
           (stdout (buffer-string))
           (stderr (with-temp-buffer
                     (insert-file-contents err-file)
                     (prog1 (buffer-string)
                       (delete-file err-file)))))
      (list exit-code stdout stderr))))

(defun mad-test--worktree-branch (wt-path)
  "Return branch name checked out in WT-PATH, or nil if detached."
  (with-temp-buffer
    (let ((exit-code (call-process "git" nil t nil "-C" wt-path
                                   "symbolic-ref" "--short" "HEAD")))
      (when (= exit-code 0)
        (string-trim (buffer-string))))))

;; --- Tests ---

(ert-deftest mad-test-script-detach-and-restore ()
  "Full round-trip: detach all, verify detached, restore all, verify restored."
  (let ((dir (make-temp-file "mad-ert-" t)))
    (unwind-protect
        (let ((repo (mad-test--create-repo dir)))
          ;; Detach
          (pcase-let ((`(,code ,stdout ,_stderr)
                       (mad-test--run-script "mad-detach" repo "main" "feat-c")))
            (should (= 0 code))
            (let ((result (json-parse-string stdout :object-type 'alist)))
              (should (= 3 (length (alist-get 'detached result))))))
          ;; Verify detached
          (dolist (wt '("wt-feat-a" "wt-feat-b" "wt-feat-c"))
            (should-not (mad-test--worktree-branch (expand-file-name wt dir))))
          ;; Restore
          (pcase-let ((`(,code ,stdout ,_stderr)
                       (mad-test--run-script "mad-restore" repo)))
            (should (= 0 code))
            (let ((result (json-parse-string stdout :object-type 'alist)))
              (should (= 3 (length (alist-get 'restored result))))))
          ;; Verify restored
          (should (equal "feat-a" (mad-test--worktree-branch (expand-file-name "wt-feat-a" dir))))
          (should (equal "feat-b" (mad-test--worktree-branch (expand-file-name "wt-feat-b" dir))))
          (should (equal "feat-c" (mad-test--worktree-branch (expand-file-name "wt-feat-c" dir)))))
      (delete-directory dir t))))

(ert-deftest mad-test-detach-refuses-with-existing-state ()
  "Second detach should fail when state file exists."
  (let ((dir (make-temp-file "mad-ert-" t)))
    (unwind-protect
        (let ((repo (mad-test--create-repo dir)))
          (mad-test--run-script "mad-detach" repo "main" "feat-c")
          (pcase-let ((`(,code ,_stdout ,stderr)
                       (mad-test--run-script "mad-detach" repo "main" "feat-c")))
            (should-not (= 0 code))
            (should (string-match-p "previous\\|already" (downcase stderr)))))
      (delete-directory dir t))))

(ert-deftest mad-test-restore-no-state ()
  "Restore with no state file should succeed with message."
  (let ((dir (make-temp-file "mad-ert-" t)))
    (unwind-protect
        (let ((repo (mad-test--create-repo dir)))
          (pcase-let ((`(,code ,stdout ,_stderr)
                       (mad-test--run-script "mad-restore" repo)))
            (should (= 0 code))
            (should (string-match-p "nothing" (downcase stdout)))))
      (delete-directory dir t))))

(ert-deftest mad-test-elisp-run-parses-output ()
  "Verify `magit-auto-detach--run' returns structured data."
  (let ((dir (make-temp-file "mad-ert-" t)))
    (unwind-protect
        (let* ((repo (mad-test--create-repo dir))
               (default-directory repo)
               (magit-auto-detach-bin-directory mad-test--bin-dir))
          ;; Mock magit-toplevel
          (cl-letf (((symbol-function 'magit-toplevel) (lambda () repo)))
            (pcase-let ((`(,code ,stdout ,stderr)
                         (magit-auto-detach--run "mad-detach" "main" "feat-c")))
              (should (= 0 code))
              (should (magit-auto-detach--parse-json stdout))
              (should (stringp stderr)))))
      (delete-directory dir t))))

(provide 'magit-auto-detach-test)
;;; magit-auto-detach-test.el ends here
```

- [ ] **Step 2: Run ERT tests**

Run: `cd /Users/danielluna/Projects/magit-auto-detach && emacs --batch \
  -L ~/.emacs.d/straight/repos/magit/lisp \
  -L ~/.emacs.d/straight/repos/transient/lisp \
  -L ~/.emacs.d/straight/repos/compat \
  -L ~/.emacs.d/straight/repos/dash \
  -L ~/.emacs.d/straight/repos/with-editor/lisp \
  -l test/magit-auto-detach-test.el \
  -f ert-run-tests-batch-and-exit`
Expected: All PASS

- [ ] **Step 3: Commit**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && git add test/magit-auto-detach-test.el
git commit -m "Add ERT tests for magit-auto-detach elisp integration"
```

### Task 9: End-to-end validation with test repo

**Files:**
- Uses: `/Users/danielluna/Projects/test-auto-detach-repo/` (created manually)

- [ ] **Step 1: Create persistent test repo**

```bash
mkdir -p /Users/danielluna/Projects/test-auto-detach-repo
cd /Users/danielluna/Projects/test-auto-detach-repo
git init -b main
git config user.email "test@test.com"
git config user.name "Test"

echo a > a.txt && git add a.txt && git commit -m "A"
echo b > b.txt && git add b.txt && git commit -m "B"
echo c > c.txt && git add c.txt && git commit -m "C" && git branch feat-a
echo d > d.txt && git add d.txt && git commit -m "D" && git branch feat-b
echo e > e.txt && git add e.txt && git commit -m "E" && git branch feat-c
git checkout --detach

git worktree add ../test-auto-detach-repo-wt-a feat-a
git worktree add ../test-auto-detach-repo-wt-b feat-b
git worktree add ../test-auto-detach-repo-wt-c feat-c
```

- [ ] **Step 2: Run full detach cycle manually**

```bash
cd /Users/danielluna/Projects/test-auto-detach-repo
~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-branches main feat-c --repo .
~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-detach main feat-c --repo .
cat .git/magit-auto-detach.json
~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/mad-restore --repo .
```

Expected: branches found → detached → state file written → restored → state file deleted

- [ ] **Step 3: Run all tests**

```bash
cd /Users/danielluna/Projects/magit-auto-detach && bundle exec rake test
emacs --batch \
  -L ~/.emacs.d/straight/repos/magit/lisp \
  -L ~/.emacs.d/straight/repos/transient/lisp \
  -L ~/.emacs.d/straight/repos/compat \
  -L ~/.emacs.d/straight/repos/dash \
  -L ~/.emacs.d/straight/repos/with-editor/lisp \
  -l test/magit-auto-detach-test.el \
  -f ert-run-tests-batch-and-exit
```

Expected: All Ruby + ERT tests PASS

- [ ] **Step 4: Clean up test repo**

```bash
cd /Users/danielluna/Projects/test-auto-detach-repo
git worktree remove ../test-auto-detach-repo-wt-a
git worktree remove ../test-auto-detach-repo-wt-b
git worktree remove ../test-auto-detach-repo-wt-c
rm -rf /Users/danielluna/Projects/test-auto-detach-repo
```

- [ ] **Step 5: Final commit in magit-auto-detach project**

```bash
cd /Users/danielluna/Projects/magit-auto-detach
git add -A
git commit -m "Complete magit-auto-detach implementation with full test coverage"
```
