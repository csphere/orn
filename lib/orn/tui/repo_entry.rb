# frozen_string_literal: true

module Orn
  module TUI
    # One discovered bare-worktree repo, with cached tmux session and agent
    # status for the sidebar. Mutable: the refresh passes update it in place.
    class RepoEntry
      attr_accessor :display_name,
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

      def initialize(display_name:, root:, healthy:, session_name:, base_branch:,
        session_alive: false, window_count: 0, expanded: false, worktrees: [],
        session_activity: nil, mru_timestamp: nil, aggregate_agent_state: nil, sbx_agent_type: nil)
        @display_name = display_name
        @root = root
        @healthy = healthy
        @session_name = session_name
        @base_branch = base_branch
        @session_alive = session_alive
        @window_count = window_count
        @expanded = expanded
        @worktrees = worktrees
        @session_activity = session_activity
        @mru_timestamp = mru_timestamp
        @aggregate_agent_state = aggregate_agent_state
        @sbx_agent_type = sbx_agent_type
      end

      def worktree_count
        @worktrees.length
      end
    end

    # One worktree row under a repo in the global tree. `dirty`/`ahead_behind`
    # stay nil until the owning repo is expanded (computed on demand).
    class WorktreeRow
      attr_accessor :branch,
        :has_window,
        :agent,
        :sandboxed,
        :dirty,
        :ahead_behind

      def initialize(branch:, has_window: false, agent: nil, sandboxed: false, dirty: nil, ahead_behind: nil)
        @branch = branch
        @has_window = has_window
        @agent = agent
        @sandboxed = sandboxed
        @dirty = dirty
        @ahead_behind = ahead_behind
      end
    end
  end
end
