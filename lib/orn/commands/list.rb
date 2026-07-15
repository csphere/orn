# frozen_string_literal: true

module Orn
  module Commands
    # `orn list`: the project's worktrees annotated with whether each has an
    # open tmux window in the project session.
    class List
      Entry = Data.define(:branch, :has_window) do
        def to_json_hash
          { "branch" => branch, "has_window" => has_window }
        end
      end

      Result = Data.define(:repo, :worktrees) do
        def to_json_hash
          { "repo" => repo, "worktrees" => worktrees.map(&:to_json_hash) }
        end
      end

      def initialize(output_mode:)
        @output_mode = output_mode
      end

      # The resolved result: worktree branches joined with the tmux window list
      # for the project session.
      def run_inner(project)
        worktree = Orn::Git::Worktree.new(root: project.root, output_mode: @output_mode)
        windows = Orn::Tmux.list_windows(@output_mode, Orn::Session.session_name(project))
        entries = worktree.entries.map { |branch| Entry.new(branch: branch, has_window: windows.include?(branch)) }
        Result.new(repo: File.basename(project.root), worktrees: entries)
      end

      def run
        result = run_inner(Orn::Git::Project.discover)
        return Commands::Output.print_json(result.to_json_hash) if @output_mode.json

        rows = result.worktrees.map { |entry| [entry.branch, entry.has_window ? "window" : "no window"] }
        Commands::Output.worktree_table(result.repo, %w[Branch Status], rows)
      end
    end
  end
end
