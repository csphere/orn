# frozen_string_literal: true

module Orn
  module TUI
    # Name and last-activity time of a live tmux session, as reported by the
    # client's session listing.
    SessionInfo = Orn::Tmux::SessionInfo

    # Live status for discovered repos: which tmux sessions are alive, their
    # window counts, per-worktree agent state and sandbox flags, and git stats
    # for expanded repos. Entries are immutable; every pass returns updated
    # copies, on the app's tmux refresh cadence.
    module RepoStatus
      # Refresh every repo's session, window, and agent status from one
      # shared pane listing, returning the updated entries. `tab` is the
      # visible hub tab, if any: its borrowed pane is attributed back to its
      # home repo and branch.
      def self.refresh(client, repos, tab, all_panes)
        sessions = client.list_sessions
        repos.map do |repo|
          info = sessions.find { |session| session.name == repo.session_name }
          borrowed = borrowed_pane_for_repo(tab, repo, all_panes)
          refreshed = if info
            alive_repo(
              client,
              repo,
              info,
              all_panes,
              borrowed
            )
          else
            dead_repo(client, repo, borrowed)
          end
          refreshed.expanded ? with_worktree_git_stats(client.output_mode, refreshed) : refreshed
        end
      end

      # The visible tab's pane remapped to its home repo and branch, so agent
      # detection attributes it correctly while it sits in the hub window.
      def self.borrowed_pane_for_repo(tab, repo, all_panes)
        return nil unless tab && tab.root.to_s == repo.root.to_s

        pane = all_panes.find { |candidate| candidate.pane_id == tab.pane_id }
        return nil unless pane

        pane.with(
          session_name: repo.session_name,
          window_name: tab.branch
        )
      end

      # A repo whose session is alive, with window and agent state refreshed.
      # The borrowed pane, when this repo owns it, stands in for its home
      # window.
      def self.alive_repo(client, repo, info, all_panes, borrowed)
        windows = client.list_windows(info.name)
        repo_panes = session_panes(repo, all_panes, borrowed)
        states = if repo_panes.empty?
          {}
        else
          Orn::Detect.detect_all_panes(client, repo_panes, repo.sbx_agent_type)
        end
        worktrees = repo.worktrees.map do |wt|
          worktree_with_agent(
            wt,
            windows,
            states,
            repo_panes
          )
        end
        repo.with(
          session_alive: true,
          session_activity: info.activity,
          window_count: windows.length,
          aggregate_agent_state: aggregate_state(states),
          worktrees: worktrees
        )
      end

      # The repo's own panes plus its borrowed hub pane (which replaces the
      # original, matched out by id).
      def self.session_panes(repo, all_panes, borrowed)
        borrowed_id = borrowed&.pane_id
        own = all_panes.select do |pane|
          pane.session_name == repo.session_name && pane.pane_id != borrowed_id
        end
        borrowed ? own + [borrowed] : own
      end

      def self.worktree_with_agent(worktree, windows, states, repo_panes)
        sandboxed = repo_panes.any? do |pane|
          pane.window_name == worktree.branch && Orn::Detect.container_runtime?(pane.pane_current_command)
        end
        worktree.with(
          has_window: windows.include?(worktree.branch),
          agent: states[worktree.branch],
          sandboxed: sandboxed
        )
      end

      # A repo whose session is gone, with its live state cleared. Borrowing
      # a repo's only pane can kill its session; the agent still runs in the
      # hub, so its status stays visible through the borrowed pane.
      def self.dead_repo(client, repo, borrowed)
        cleared = repo.with(
          session_alive: false,
          session_activity: nil,
          window_count: 0,
          aggregate_agent_state: nil,
          worktrees: repo.worktrees.map do |wt|
            wt.with(
              has_window: false,
              agent: nil,
              sandboxed: false
            )
          end
        )
        return cleared unless borrowed

        attribute_borrowed_agent(client, cleared, borrowed)
      end

      def self.attribute_borrowed_agent(client, repo, borrowed)
        branch = borrowed.window_name
        states = Orn::Detect.detect_all_panes(client, [borrowed], repo.sbx_agent_type)
        worktrees = repo.worktrees.map do |wt|
          next wt unless wt.branch == branch

          wt.with(
            agent: states[branch],
            sandboxed: Orn::Detect.container_runtime?(borrowed.pane_current_command)
          )
        end
        repo.with(
          aggregate_agent_state: aggregate_state(states),
          worktrees: worktrees
        )
      end

      # Highest-priority state among panes hosting an agent (blocked > working
      # > idle), or nil when no agent is detected.
      def self.aggregate_state(states)
        agents = states.values.select(&:agent)
        return nil if agents.empty?

        agents.map(&:state).max_by { |state| Orn::Detect.state_priority(state) }
      end

      # The repo with dirty and ahead/behind stats filled in. Gathered only
      # for expanded repos, on the tmux refresh cadence, to keep the collapsed
      # global view cheap.
      def self.with_worktree_git_stats(output, repo)
        worktrees = repo.worktrees.map do |wt|
          wt_path = File.join(repo.root.to_s, wt.branch)
          wt.with(
            dirty: GitStats.dirty?(output, wt_path),
            ahead_behind: GitStats.ahead_behind(
              output,
              wt_path,
              wt.branch,
              repo.base_branch
            )
          )
        end
        repo.with(worktrees: worktrees)
      end
    end
  end
end
