# frozen_string_literal: true

module Orn
  module Commands
    module Wt
      # `orn wt list`: the project's worktree branches as a plain list (table
      # for humans, or the resolved result as JSON).
      class List
        Result = Data.define(:repo, :worktrees)

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run
          result = run_inner
          if @output_mode.json
            Commands::Output.print_json("repo" => result.repo, "worktrees" => result.worktrees)
          else
            Commands::Output.worktree_table(result.repo, ["Branch"], result.worktrees.map { |branch| [branch] })
          end
        end

        # The resolved result (repo name + worktree branches), the serializable
        # value used for --json.
        def run_inner
          project = Orn::Git::Project.discover
          worktree = Orn::Git::Worktree.new(root: project.root, output_mode: @output_mode)
          Result.new(repo: File.basename(project.root), worktrees: worktree.entries)
        end
      end
    end
  end
end
