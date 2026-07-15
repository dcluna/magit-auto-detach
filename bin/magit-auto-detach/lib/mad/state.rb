require "json"
require "time"

module Mad
  class State
    class NotFoundError < StandardError; end

    STATE_VERSION = 2

    def initialize(path)
      @path = path
    end

    def exists?
      File.exist?(@path)
    end

    def create_or_open(base_ref:, tip_ref:)
      if exists?
        add_range(base_ref, tip_ref)
      else
        data = {
          "version" => STATE_VERSION,
          "created_at" => Time.now.utc.iso8601,
          "ranges" => [[base_ref, tip_ref]],
          "entries" => []
        }
        write_data(data)
      end
    end

    def read
      raise NotFoundError, "No state file at: #{@path}" unless exists?
      JSON.parse(File.read(@path))
    end

    def add_range(base_ref, tip_ref)
      data = read
      pair = [base_ref, tip_ref]
      data["ranges"] << pair unless data["ranges"].include?(pair)
      write_data(data)
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

    def branches
      entries.map { |e| e["branch"] }.to_set
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
