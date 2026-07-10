require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require "shellwords"

$LOAD_PATH.unshift(File.expand_path("~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach/lib"))

BIN_DIR = File.expand_path("~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach")

module RepoFixture
  def create_test_repo(dir)
    repo = File.join(dir, "repo")
    FileUtils.mkdir_p(repo)

    git(repo, "init", "-b", "main")
    git(repo, "config", "user.email", "test@test.com")
    git(repo, "config", "user.name", "Test")

    File.write(File.join(repo, "a.txt"), "a")
    git(repo, "add", "a.txt")
    git(repo, "commit", "-m", "A")

    File.write(File.join(repo, "b.txt"), "b")
    git(repo, "add", "b.txt")
    git(repo, "commit", "-m", "B")

    File.write(File.join(repo, "c.txt"), "c")
    git(repo, "add", "c.txt")
    git(repo, "commit", "-m", "C")
    git(repo, "branch", "feat-a")

    File.write(File.join(repo, "d.txt"), "d")
    git(repo, "add", "d.txt")
    git(repo, "commit", "-m", "D")
    git(repo, "branch", "feat-b")

    File.write(File.join(repo, "e.txt"), "e")
    git(repo, "add", "e.txt")
    git(repo, "commit", "-m", "E")
    git(repo, "branch", "feat-c")

    git(repo, "worktree", "add", File.join(dir, "wt-feat-a"), "feat-a")
    git(repo, "worktree", "add", File.join(dir, "wt-feat-b"), "feat-b")
    git(repo, "worktree", "add", File.join(dir, "wt-feat-c"), "feat-c")

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
