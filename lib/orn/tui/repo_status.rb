# frozen_string_literal: true

module Orn
  module TUI
    # Name and last-activity time of a live tmux session.
    SessionInfo = Data.define(:name, :activity)

    # Live status for discovered repos: which tmux sessions are alive, their
    # window counts, per-worktree agent state and sandbox flags, and git stats
    # for expanded repos. Updates RepoEntry/WorktreeRow fields in place, on
    # the app's tmux refresh cadence.
    module RepoStatus
      # Update every repo's session, window, and agent status from one shared
      # pane listing. `tab` is the visible hub tab, if any: its borrowed pane
      # is attributed back to its home repo and branch.
      def self.refresh(output, repos, tab, all_panes)
        sessions = list_sessions(output)
        repos.each do |repo|
          info = sessions.find { |session| session.name == repo.session_name }
          borrowed = borrowed_pane_for_repo(
            tab,
            repo,
            all_panes
          )
          if info
            refresh_alive_repo(
              output,
              repo,
              info,
              all_panes,
              borrowed
            )
          else
            refresh_dead_repo(
              output,
              repo,
              borrowed
            )
          end
          refresh_worktree_git_stats(output, repo) if repo.expanded
        end
      end

      def self.list_sessions(output)
        result = Orn::Cmd.new(output_mode: output)
          .output("tmux", "list-sessions", "-F", "\#{session_name}\t\#{session_activity}")
        return [] unless result.success?

        result.stdout.lines.filter_map do |line|
          name, activity = line.chomp.split("\t", 2)
          activity && SessionInfo.new(
            name: name,
            activity: activity.to_i
          )
        end
      rescue Orn::Error
        []
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

      # Refresh window and agent state for a repo whose session is alive. The
      # borrowed pane, when this repo owns it, stands in for its home window.
      def self.refresh_alive_repo(output, repo, info, all_panes, borrowed)
        repo.session_alive = true
        repo.session_activity = info.activity
        windows = Orn::Tmux.list_windows(output, info.name)
        repo.window_count = windows.length

        repo_panes = session_panes(
          repo,
          all_panes,
          borrowed
        )
        states = if repo_panes.empty?
          {}
        else
          Orn::Detect.detect_all_panes(
            output,
            repo_panes,
            repo.sbx_agent_type
          )
        end
        repo.aggregate_agent_state = aggregate_state(states)
        repo.worktrees.each do |wt|
          assign_worktree_agent(
            wt,
            windows,
            states,
            repo_panes
          )
        end
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

      def self.assign_worktree_agent(worktree, windows, states, repo_panes)
        worktree.has_window = windows.include?(worktree.branch)
        worktree.agent = states[worktree.branch]
        worktree.sandboxed = repo_panes.any? do |pane|
          pane.window_name == worktree.branch && Orn::Detect.container_command?(pane.pane_current_command)
        end
      end

      # Borrowing a repo's only pane can kill its session; the agent still
      # runs in the hub, so its status stays visible through the borrowed
      # pane.
      def self.refresh_dead_repo(output, repo, borrowed)
        repo.session_alive = false
        repo.session_activity = nil
        repo.window_count = 0
        repo.aggregate_agent_state = nil
        repo.worktrees.each do |wt|
          wt.has_window = false
          wt.agent = nil
          wt.sandboxed = false
        end
        return unless borrowed

        attribute_borrowed_agent(
          output,
          repo,
          borrowed
        )
      end

      def self.attribute_borrowed_agent(output, repo, borrowed)
        branch = borrowed.window_name
        states = Orn::Detect.detect_all_panes(
          output,
          [borrowed],
          repo.sbx_agent_type
        )
        repo.aggregate_agent_state = aggregate_state(states)
        worktree = repo.worktrees.find { |wt| wt.branch == branch }
        return unless worktree

        worktree.agent = states[branch]
        worktree.sandboxed = Orn::Detect.container_command?(borrowed.pane_current_command)
      end

      # Highest-priority state among panes hosting an agent (blocked > working
      # > idle), or nil when no agent is detected.
      def self.aggregate_state(states)
        agents = states.values.select(&:agent)
        return nil if agents.empty?

        agents.map(&:state).max_by { |state| Orn::Detect.state_priority(state) }
      end

      # Dirty and ahead/behind stats are gathered only for expanded repos, on
      # the tmux refresh cadence, to keep the collapsed global view cheap.
      def self.refresh_worktree_git_stats(output, repo)
        repo.worktrees.each do |wt|
          wt_path = File.join(repo.root.to_s, wt.branch)
          wt.dirty = App.dirty?(output, wt_path)
          wt.ahead_behind = App.ahead_behind(
            output,
            wt_path,
            wt.branch,
            repo.base_branch
          )
        end
      end
    end
  end
end
