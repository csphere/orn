# frozen_string_literal: true

module Orn
  module Commands
    # `orn list`: the project's worktrees annotated with whether each has an
    # open tmux window in the project session.
    class List
      Entry = Data.define(:branch, :has_window) do
        def to_json_hash
          {
            "branch" => branch,
            "has_window" => has_window
          }
        end
      end

      Result = Data.define(:repo, :worktrees) do
        def to_json_hash
          {
            "repo" => repo,
            "worktrees" => worktrees.map(&:to_json_hash)
          }
        end
      end

      def initialize(output_mode:, client: nil)
        @output_mode = output_mode
        @client = client || Orn::Tmux::Client.new(output_mode: output_mode)
      end

      # The resolved result: worktree branches joined with the tmux window list
      # for the project session.
      def run_inner(project)
        worktree = Orn::Git::Worktree.new(
          root: project.root,
          output_mode: @output_mode
        )
        windows = @client.list_windows(Orn::Session.session_name(project))
        entries = worktree.branches.map do |branch|
          Entry.new(
            branch: branch,
            has_window: windows.include?(branch)
          )
        end
        Result.new(
          repo: File.basename(project.root),
          worktrees: entries
        )
      end

      def run
        result = run_inner(Orn::Git::Project.discover)
        return Commands::Output.print_json(result.to_json_hash) if @output_mode.json

        rows = result.worktrees.map { |entry| [entry.branch, entry.has_window ? "window" : "no window"] }
        Commands::Output.worktree_table(
          result.repo,
          %w[Branch Status],
          rows
        )
      end
    end
  end
end
