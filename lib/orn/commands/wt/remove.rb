# frozen_string_literal: true

module Orn
  module Commands
    module Wt
      # `orn wt remove`: delete worktrees and, with --prune, their local and
      # remote branches. Removes each branch's blackboard entry and prunes
      # now-empty parent directories. Batch: one branch's failure is reported
      # but does not stop the rest.
      class Remove
        Result = Data.define(:branch, :worktree_removed, :branch_deleted, :remote_branch_deleted) do
          def to_json_hash
            {
              "branch" => branch,
              "worktree_removed" => worktree_removed,
              "branch_deleted" => branch_deleted,
              "remote_branch_deleted" => remote_branch_deleted
            }
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run(branches, prune:, force:)
          branches.each { |branch| Orn::Git::BranchName.new(branch).validate! }
          project = Orn::Git::Project.discover
          confirm_prunes(project, branches) if prune && !force && !@output_mode.json

          results, errors = remove_multiple(project, branches, prune, prune)
          json = results.map(&:to_json_hash)
          Commands::Output.finish_multi_branch(@output_mode, json, errors, branches.length)
        end

        def remove_multiple(project, branches, prune, prune_remote)
          printer = ->(result) { print_result(result) }
          Commands::Output.run_multi_branch(@output_mode, branches, printer) do |branch|
            run_inner_with_remote(project, branch, prune, prune_remote)
          end
        end

        # Removes one branch's worktree, then optionally its local (prune) and
        # remote (prune_remote) branches, plus its blackboard entry and any
        # now-empty parent directories. Refuses to prune the base branch or to
        # run from inside the worktree being removed; a missing worktree is not
        # an error, so prune-only invocations work.
        def run_inner_with_remote(project, branch, prune, prune_remote)
          reject_base_prune!(project, branch, prune, prune_remote)
          reject_inside_worktree!(project, branch)

          worktree = Orn::Git::Worktree.new(root: project.root, output_mode: @output_mode)
          worktree_removed = remove_worktree(worktree, project.worktree_path(branch))
          branch_deleted = prune ? worktree.delete_branch(branch) : false
          remote_branch_deleted = prune_remote ? worktree.delete_remote_branch(branch) : false

          Orn::Blackboard.remove_entry(project.root, branch)
          Orn::Fs.prune_empty_dirs(project.root)

          Result.new(
            branch: branch,
            worktree_removed: worktree_removed,
            branch_deleted: branch_deleted,
            remote_branch_deleted: remote_branch_deleted
          )
        end

        private

        def reject_base_prune!(project, branch, prune, prune_remote)
          return unless (prune || prune_remote) && branch == project.config.base

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

        def current_directory
          Dir.pwd
        rescue SystemCallError
          nil
        end

        def confirm_prunes(project, branches)
          branches.each { |branch| Orn::Confirm.prune_interactive(project.root, branch) }
        end

        def print_result(result)
          puts worktree_message(result)
          puts "Deleted branch: #{result.branch}" if result.branch_deleted
          puts "Deleted remote branch: #{result.branch}" if result.remote_branch_deleted
        end

        def worktree_message(result)
          return "Removed worktree: #{result.branch}" if result.worktree_removed

          "No worktree found for #{result.branch}"
        end
      end
    end
  end
end
