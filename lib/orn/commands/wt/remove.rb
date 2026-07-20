# frozen_string_literal: true

module Orn
  module Commands
    module Wt
      # `orn wt remove`: delete worktrees and, with --prune, their local and
      # remote branches. Batch: one branch's failure is reported but does not
      # stop the rest.
      class Remove
        Result = Data.define(
          :branch,
          :worktree_removed,
          :branch_deleted,
          :remote_branch_deleted
        ) do
          def to_json_hash
            {
              "branch" => branch,
              "worktree_removed" => worktree_removed,
              "branch_deleted" => branch_deleted,
              "remote_branch_deleted" => remote_branch_deleted
            }
          end

          # The human-readable removal summary; shared with the top-level
          # `orn remove`, which layers window/sandbox lines on top.
          def print_summary
            puts(worktree_removed ? "Removed worktree: #{branch}" : "No worktree found for #{branch}")
            puts "Deleted branch: #{branch}" if branch_deleted
            puts "Deleted remote branch: #{branch}" if remote_branch_deleted
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run(branches, prune:, force:)
          BranchBatch.run(
            @output_mode,
            branches,
            prune: prune,
            force: force
          ) do |project, branch|
            run_inner(
              project,
              branch,
              prune
            )
          end
        end

        # All preconditions for removing this branch, raised before anything
        # is destroyed. The top-level `orn remove` runs this first so the
        # sandbox and tmux window survive when removal would be refused.
        def check_removable!(project, branch, prune)
          reject_base_prune!(
            project,
            branch,
            prune
          )
          reject_inside_worktree!(project, branch)
        end

        # Removes one branch's worktree, then with prune its local and remote
        # branches. Refuses to prune the base branch or to run from inside
        # the worktree being removed; a missing worktree is not an error, so
        # prune-only invocations work.
        def run_inner(project, branch, prune)
          check_removable!(
            project,
            branch,
            prune
          )

          worktree = Orn::Git::Worktree.new(
            root: project.root,
            output_mode: @output_mode
          )
          worktree_removed = remove_worktree(worktree, project.worktree_path(branch))
          branch_deleted = prune ? prune_branch(worktree, branch) : false
          remote_branch_deleted = prune ? prune_remote_branch(worktree, branch) : false

          Orn::Fs.prune_branch_dirs(project.root, branch)

          Result.new(
            branch: branch,
            worktree_removed: worktree_removed,
            branch_deleted: branch_deleted,
            remote_branch_deleted: remote_branch_deleted
          )
        end

        private

        def reject_base_prune!(project, branch, prune)
          return unless prune && branch == project.config.base

          raise Orn::Error, "Cannot prune the base branch '#{branch}'"
        end

        def reject_inside_worktree!(project, branch)
          cwd = current_directory
          return if cwd.nil? || !Orn::Fs.within?(cwd, project.worktree_path(branch))

          raise Orn::Error,
            "Cannot remove worktree for '#{branch}' while inside it\n  " \
              "cd out of the worktree directory or run from a different window"
        end

        def remove_worktree(worktree, wt_path)
          return false unless File.exist?(wt_path)

          worktree.remove(wt_path)
          true
        end

        # Failed deletions warn instead of raising (the batch keeps going),
        # because a missing "Deleted branch" line alone reads as success.
        def prune_branch(worktree, branch)
          report_prune_failure("local branch", branch, worktree.delete_branch(branch))
        end

        def prune_remote_branch(worktree, branch)
          report_prune_failure("remote branch", branch, worktree.delete_remote_branch(branch))
        end

        def report_prune_failure(kind, branch, result)
          return true if result.success?

          stderr = result.stderr.strip
          detail = stderr.empty? ? "" : ": #{stderr}"
          @output_mode.status("warning: could not delete #{kind} '#{branch}'#{detail}")
          false
        end

        def current_directory
          Dir.pwd
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
