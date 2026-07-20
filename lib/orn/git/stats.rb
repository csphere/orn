# frozen_string_literal: true

module Orn
  module Git
    # Working-tree stats consumed by the TUIs: dirtiness and ahead/behind
    # counts for a worktree.
    module Stats
      # True when `git status --porcelain` reports changes; false on any git
      # failure.
      def self.dirty?(output_mode, wt_path)
        repo = Orn::Git::Repo.new(
          dir: wt_path,
          output_mode: output_mode
        )
        !repo.read("status", "--porcelain").to_s.strip.empty?
      end

      # Commit counts of `branch` ahead of and behind `base`; (0, 0) on any git
      # failure.
      def self.ahead_behind(output_mode, wt_path, branch, base)
        repo = Orn::Git::Repo.new(
          dir: wt_path,
          output_mode: output_mode
        )
        stdout = repo.read(
          "rev-list",
          "--left-right",
          "--count",
          "#{branch}...#{base}"
        )
        return [0, 0] if stdout.nil?

        parts = stdout.split
        parts.length == 2 ? [parts[0].to_i, parts[1].to_i] : [0, 0]
      end
    end
  end
end
