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
      commits = output.split("\n").reject(&:empty?)
      # Include the base commit itself so branches at the base ref get found
      base_sha = rev_parse(base)
      commits << base_sha unless commits.include?(base_sha)
      commits
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
      _stdout, stderr, status = Open3.capture3("git", "-C", worktree_path, "checkout", "--detach")
      return if detached?(worktree_path)
      raise CommandError, "git checkout --detach in #{worktree_path} failed: #{stderr}" unless status.success?
    end

    def checkout_branch(worktree_path, branch)
      _stdout, stderr, status = Open3.capture3("git", "-C", worktree_path, "checkout", branch)
      actual = current_branch(worktree_path)
      return if actual == branch
      raise CommandError, "git checkout #{branch} in #{worktree_path} failed: #{stderr}" unless status.success?
      raise CommandError, "git checkout #{branch} in #{worktree_path} failed: HEAD on #{actual || 'detached'}, not #{branch}"
    end

    def detached?(worktree_path)
      _stdout, stderr, status = Open3.capture3("git", "-C", worktree_path, "symbolic-ref", "HEAD")
      return false if status.success?
      return true if stderr.include?("not a symbolic ref")
      raise CommandError, "git symbolic-ref in #{worktree_path} failed: #{stderr}"
    end

    def current_branch(worktree_path)
      stdout, status = Open3.capture2("git", "-C", worktree_path, "symbolic-ref", "--short", "HEAD")
      status.success? ? stdout.strip : nil
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
