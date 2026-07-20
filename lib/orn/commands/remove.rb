# frozen_string_literal: true

module Orn
  module Commands
    # `orn remove`: tear down a branch's sandbox, tmux window, and worktree,
    # optionally pruning the local and remote branches. The TUI hub pane-return
    # is a follow-up. Batch: one branch's failure is reported but does not
    # stop the rest.
    class Remove
      Result = Data.define(
        :sandbox_removed,
        :window_closed,
        :wt
      ) do
        def branch
          wt.branch
        end

        # sandbox/window flags plus the flattened worktree-removal fields.
        def to_json_hash
          {
            "sandbox_removed" => sandbox_removed,
            "window_closed" => window_closed
          }.merge(wt.to_json_hash)
        end

        def print_summary
          puts "Removed sandbox for #{branch}" if sandbox_removed
          puts "Closed tmux window: #{branch}" if window_closed
          wt.print_summary
        end
      end

      def initialize(output_mode:, client: nil)
        @output_mode = output_mode
        @client = client || Orn::Tmux::Client.new(output_mode: output_mode)
      end

      # Removes one branch's sandbox (with its ports file) and tmux window,
      # then delegates worktree and branch removal to Wt::Remove. Called once
      # per branch by the CLI batch path. Guards run first: killing the
      # window before them could take down the very window orn runs in, or
      # leave a half-removed branch when the worktree removal is refused.
      def run_inner(project, branch, prune)
        wt_remove = Wt::Remove.new(output_mode: @output_mode)
        wt_remove.check_removable!(
          project,
          branch,
          prune
        )

        session = Orn::Session.session_name(project)
        sandbox_removed = teardown_sandbox(project, branch)
        window_closed = close_window(session, branch)
        wt_result = wt_remove.run_inner(
          project,
          branch,
          prune
        )
        Result.new(
          sandbox_removed: sandbox_removed,
          window_closed: window_closed,
          wt: wt_result
        )
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

      private

      # Best-effort sandbox teardown: `try_remove` returns false when no sandbox
      # (or no sbx CLI) exists; the ports file is deleted only on a real removal.
      def teardown_sandbox(project, branch)
        sbx_name = project.sandbox_name(branch)
        removed = Orn::Sandbox::SbxCli.try_remove(@output_mode, sbx_name)
        Orn::Sandbox::Ports.remove_ports_file(File.join(project.root, ".orn"), sbx_name) if removed
        removed
      end

      def close_window(session, branch)
        return false unless @client.window_exists?(session, branch)

        @client.kill_window(session, branch)
        true
      end
    end
  end
end
