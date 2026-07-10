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
