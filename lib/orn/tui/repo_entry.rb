# frozen_string_literal: true

module Orn
  module TUI
    # One discovered bare-worktree repo, with cached tmux session and agent
    # status for the sidebar. Immutable: the refresh passes build updated
    # copies via `with`.
    RepoEntry = Data.define(
      :display_name,
      :root,
      :healthy,
      :session_name,
      :base_branch,
      :session_alive,
      :window_count,
      :expanded,
      :worktrees,
      :session_activity,
      :mru_timestamp,
      :aggregate_agent_state,
      :sbx_agent_type
    ) do
      def initialize(display_name:, root:, healthy:, session_name:, base_branch:,
        session_alive: false, window_count: 0, expanded: false, worktrees: [],
        session_activity: nil, mru_timestamp: nil, aggregate_agent_state: nil, sbx_agent_type: nil)
        super
      end

      def worktree_count
        worktrees.length
      end
    end

    # One worktree row under a repo in the global tree. `dirty`/`ahead_behind`
    # stay nil until the owning repo is expanded (computed on demand).
    WorktreeRow = Data.define(
      :branch,
      :has_window,
      :agent,
      :sandboxed,
      :dirty,
      :ahead_behind
    ) do
      def initialize(branch:, has_window: false, agent: nil, sandboxed: false, dirty: nil, ahead_behind: nil)
        super
      end
    end
  end
end
