# frozen_string_literal: true

module Orn
  module Commands
    module Wt
      # `orn wt open`: resolve a branch to its worktree path, creating the
      # worktree from the remote branch when it only exists on origin.
      # Worktree-only (no tmux window).
      class Open
        Result = Data.define(
          :branch,
          :path,
          :created
        )

        # Returns the existing worktree path, or fetches and creates the worktree
        # when the branch exists only on origin; raises when the branch exists in
        # neither place.
        def self.resolve(output_mode, project, branch)
          wt_path = project.worktree_path(branch)
          if File.exist?(wt_path)
            return Result.new(
              branch: branch,
              path: wt_path.to_s,
              created: false
            )
          end

          output_mode.status("Checking remote for #{branch}...")
          worktree = Orn::Git::Worktree.new(
            root: project.root,
            output_mode: output_mode
          )
          if worktree.remote_branch_exists?("origin", branch)
            created = New.create(
              output_mode,
              project,
              branch,
              nil
            )
            return Result.new(
              branch: branch,
              path: created.worktree_path,
              created: true
            )
          end

          raise Orn::Error,
            "No worktree found for '#{branch}'\n  " \
              "Branch does not exist on the remote either\n  " \
              "Use 'orn new #{branch}' to create it"
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run(branch)
          Orn::Git::BranchName.new(branch).validate!

          project = Orn::Git::Project.discover
          result = self.class.resolve(
            @output_mode,
            project,
            branch
          )
          emit(result)
        end

        private

        def emit(result)
          return Commands::Output.print_json(result.to_h) if @output_mode.json

          if result.created
            puts "Created worktree from remote: #{result.path}"
          else
            puts "Worktree: #{result.path}"
          end
        end
      end
    end
  end
end
