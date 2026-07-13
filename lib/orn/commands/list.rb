# frozen_string_literal: true

module Orn
  module Commands
    # `orn list`: the project's worktrees annotated with whether each has an
    # open tmux window in the project session.
    class List
      Entry = Data.define(:branch, :has_window)
      Result = Data.define(:repo, :worktrees)

      def initialize(output_mode:)
        @output_mode = output_mode
      end

      def run
        result = run_inner
        return emit_json(result) if @output_mode.json

        rows = result.worktrees.map { |entry| [entry.branch, entry.has_window ? "window" : "no window"] }
        Commands::Output.worktree_table(result.repo, %w[Branch Status], rows)
      end

      # The resolved result: worktree branches joined with the tmux window list
      # for the project session.
      def run_inner
        project = Orn::Git::Project.discover
        worktree = Orn::Git::Worktree.new(root: project.root, output_mode: @output_mode)
        windows = Orn::Tmux.list_windows(@output_mode, Orn::Session.session_name(project))
        entries = worktree.entries.map { |branch| Entry.new(branch: branch, has_window: windows.include?(branch)) }
        Result.new(repo: File.basename(project.root), worktrees: entries)
      end

      private

      def emit_json(result)
        worktrees = result.worktrees.map { |entry| { "branch" => entry.branch, "has_window" => entry.has_window } }
        Commands::Output.print_json("repo" => result.repo, "worktrees" => worktrees)
      end
    end
  end
end
