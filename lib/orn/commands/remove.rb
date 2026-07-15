# frozen_string_literal: true

module Orn
  module Commands
    # `orn remove`: tear down a branch's sandbox, tmux window, and worktree,
    # optionally pruning the local and remote branches. The TUI hub pane-return
    # is a follow-up. Batch: one branch's failure is reported but does not
    # stop the rest.
    class Remove
      Result = Data.define(:sandbox_removed, :window_closed, :wt) do
        def branch
          wt.branch
        end

        # sandbox/window flags plus the flattened worktree-removal fields.
        def to_json_hash
          { "sandbox_removed" => sandbox_removed, "window_closed" => window_closed }.merge(wt.to_json_hash)
        end

        def print_summary
          puts "Removed sandbox for #{branch}" if sandbox_removed
          puts "Closed tmux window: #{branch}" if window_closed
          wt.print_summary
        end
      end

      # Removes one branch's sandbox (with its ports file) and tmux window,
      # then delegates worktree and branch removal to Wt::Remove. Called once
      # per branch by the CLI batch path.
      def self.run_inner(output_mode, project, branch, prune)
        session = Orn::Session.session_name(project)
        sandbox_removed = teardown_sandbox(output_mode, project, branch)
        window_closed = close_window(output_mode, session, branch)
        wt_result = Wt::Remove.new(output_mode: output_mode)
          .run_inner(project, branch, prune)
        Result.new(sandbox_removed: sandbox_removed, window_closed: window_closed, wt: wt_result)
      end

      # Best-effort sandbox teardown: `try_remove` returns false when no sandbox
      # (or no sbx CLI) exists; the ports file is deleted only on a real removal.
      def self.teardown_sandbox(output_mode, project, branch)
        sbx_name = project.sandbox_name(branch)
        removed = Orn::Sandbox.try_remove(output_mode, sbx_name)
        Orn::Sandbox.remove_ports_file(File.join(project.root, ".orn"), sbx_name) if removed
        removed
      end

      def self.close_window(output_mode, session, branch)
        return false unless Orn::Tmux.window_exists?(output_mode, session, branch)

        Orn::Tmux.kill_window(output_mode, session, branch)
        true
      end

      def initialize(output_mode:)
        @output_mode = output_mode
      end

      def run(branches, prune:, force:)
        branches.each { |branch| Orn::Git::BranchName.new(branch).validate! }
        project = Orn::Git::Project.discover
        confirm_prunes(project, branches) if prune && !force && !@output_mode.json

        results, errors = remove_multiple(project, branches, prune)
        json = results.map(&:to_json_hash)
        Commands::Output.finish_multi_branch(@output_mode, json, errors, branches.length)
      end

      private

      def remove_multiple(project, branches, prune)
        printer = lambda(&:print_summary)
        Commands::Output.run_multi_branch(@output_mode, branches, printer) do |branch|
          self.class.run_inner(@output_mode, project, branch, prune)
        end
      end

      def confirm_prunes(project, branches)
        branches.each { |branch| Orn::Confirm.prune_interactive(project.root, branch) }
      end
    end
  end
end
