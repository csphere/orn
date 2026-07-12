# frozen_string_literal: true

module Orn
  module Git
    # Git worktree and branch operations for a project, run against the
    # project root via `git -C <root>`.
    class Worktree
      def initialize(root:, output_mode:)
        @root = root
        @cmd = Orn::Cmd.new(output_mode: output_mode)
      end

      # Advisory: false on any git failure (missing branch, git error). Not a
      # hard guarantee that the branch is absent.
      def local_branch_exists?(branch)
        git_output("rev-parse", "--verify", "refs/heads/#{branch}").success?
      rescue Orn::Error
        false
      end

      # Advisory, like local_branch_exists?, but consults the remote.
      def remote_branch_exists?(remote, branch)
        result = git_output("ls-remote", "--heads", remote, branch)
        result.success? && !result.stdout.strip.empty?
      rescue Orn::Error
        false
      end

      # Fetches branch from remote so it can be used as a worktree start point.
      def fetch(remote, branch)
        git_exec("fetch", remote, branch)
      end

      # Creates a worktree for branch, trying three strategies in order: new
      # branch from start_point, new branch from its local equivalent (with any
      # origin/ prefix stripped), then checkout of an existing local branch.
      # The raised error collects stderr from every failed attempt.
      def add(path, branch, start_point)
        errors = []
        succeeded = false

        add_attempts(path, branch, start_point).each_with_index do |args, index|
          result = git_output(*args)
          if result.success?
            succeeded = true
            break
          end

          stderr = result.stderr.strip
          errors << "  Attempt #{index + 1}: #{stderr}" unless stderr.empty?
        end

        raise Orn::Error, add_failure_message(branch, errors) unless succeeded
      end

      # Removes the worktree at path with --force, discarding uncommitted
      # changes. The branch itself is left intact.
      def remove(path)
        git_exec("worktree", "remove", "--force", path)
      end

      # Force-deletes the local branch; returns whether git succeeded.
      def delete_branch(branch)
        git_output("branch", "-D", branch).success?
      end

      # Deletes branch on origin; returns whether git succeeded.
      def delete_remote_branch(branch)
        git_output("push", "origin", "--delete", branch).success?
      end

      # The sorted branch names of all worktrees, parsed from `git worktree
      # list --porcelain`. Skips bare/detached entries and the project root
      # itself; a failed git call yields an empty list.
      def entries
        result = git_output("worktree", "list", "--porcelain")
        return [] unless result.success?

        parse_entries(result.stdout).sort
      end

      private

      # The three worktree-creation strategies tried in order: new branch from
      # start_point, new branch from its local equivalent (origin/ stripped),
      # then checkout of an existing local branch.
      def add_attempts(path, branch, start_point)
        local_start_point = start_point.delete_prefix("origin/")
        [
          ["worktree", "add", "-b", branch, path, start_point],
          ["worktree", "add", "-b", branch, path, local_start_point],
          ["worktree", "add", path, branch]
        ]
      end

      def git_output(*args)
        @cmd.output("git", "-C", @root, *args)
      end

      def git_exec(*args)
        @cmd.exec("git", "-C", @root, *args)
      end

      def add_failure_message(branch, errors)
        base = "Failed to create worktree for '#{branch}'"
        return base if errors.empty?

        "#{base}\n#{errors.join("\n")}"
      end

      def parse_entries(porcelain)
        entries = []
        current_path = nil
        current_branch = nil

        # The trailing "" sentinel flushes the last block even when the
        # porcelain output does not end with a blank line.
        (porcelain.lines(chomp: true) + [""]).each do |line|
          if line.start_with?("worktree ")
            current_path = line.delete_prefix("worktree ")
            current_branch = nil
          elsif line.start_with?("branch refs/heads/")
            current_branch = line.delete_prefix("branch refs/heads/")
          elsif line.empty?
            entries << current_branch if current_branch && current_path != @root
            current_path = nil
            current_branch = nil
          end
        end
        entries
      end
    end
  end
end
