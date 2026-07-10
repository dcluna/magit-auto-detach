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
