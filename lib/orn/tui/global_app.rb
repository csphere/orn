# frozen_string_literal: true

module Orn
  module TUI
    # A visible row in the flattened repo/worktree tree: a repo header or a
    # worktree under it, identified by index into `entries`.
    TreeRow = Data.define(
      :kind,
      :repo_index,
      :wt_index
    ) do
      def self.repo(repo_index)
        new(
          kind: :repo,
          repo_index: repo_index,
          wt_index: nil
        )
      end

      def self.worktree(repo_index, wt_index)
        new(
          kind: :worktree,
          repo_index: repo_index,
          wt_index: wt_index
        )
      end

      def repo? = kind == :repo
      def worktree? = kind == :worktree
    end

    # Identifies a row by content (repo root, or root + branch) rather than
    # position, so the selection can follow it across a resort instead of
    # drifting to whatever now occupies its old index.
    RowIdentity = Data.define(
      :kind,
      :root,
      :branch
    ) do
      def self.repo(root)
        new(
          kind: :repo,
          root: root.to_s,
          branch: nil
        )
      end

      def self.worktree(root, branch)
        new(
          kind: :worktree,
          root: root.to_s,
          branch: branch
        )
      end
    end

    # Name and last-activity time of a live tmux session.
    SessionInfo = Data.define(:name, :activity)

    # Agent-tab state for the hub window: which tabs are open, which one (if
    # any) is visible, and where the hub itself lives in tmux. Kept separate
    # from GlobalApp's repo/sidebar state since it has its own lifecycle, tied
    # to tmux rather than to the discovery/mru refresh cycle.
    class HubState
      attr_reader :tabs,
        :hub_pane,
        :hub_location
      attr_accessor :agent_focused

      def initialize(hub_pane, hub_location)
        @tabs = []
        @visible_tab = nil
        @agent_focused = false
        @hub_pane = hub_pane
        @hub_location = hub_location
      end

      def visible
        @visible_tab && @tabs[@visible_tab]
      end

      def visible_index
        @visible_tab
      end

      def visible_index=(index)
        @visible_tab = index
      end

      def take_visible
        taken = @visible_tab
        @visible_tab = nil
        taken
      end

      def tab_index_for(root, branch)
        @tabs.index { |tab| tab.root.to_s == root.to_s && tab.branch == branch }
      end

      def push_tab(tab)
        @tabs.push(tab)
        @tabs.length - 1
      end

      def remove_tab(index)
        @tabs.delete_at(index)
        @visible_tab = Hub.adjust_visible_after_remove(@visible_tab, index)
      end

      def clear_tabs
        @tabs.clear
        @visible_tab = nil
      end

      # Drop tabs whose panes no longer exist (closed underneath us). Returns
      # true when the visible tab was among them, so the caller can tear down
      # key bindings.
      def prune_dead_tabs(all_panes)
        had_visible = !@visible_tab.nil?
        index = 0
        while index < @tabs.length
          if Hub.tab_pane_alive(@tabs[index], all_panes)
            index += 1
          else
            remove_tab(index)
          end
        end
        had_visible && @visible_tab.nil?
      end

      # A visible tab's pane can be moved out of the hub behind our back (e.g.
      # `orn switch` returned it home). Demote such a tab to hidden, returning
      # true when it did so, so the caller can tear down key bindings.
      def demote_visible_if_moved(all_panes)
        location = @hub_location
        tab = visible
        return false unless location && tab

        hub_session, hub_window = location
        in_hub = all_panes.any? do |pane|
          pane.pane_id == tab.pane_id &&
            pane.session_name == hub_session &&
            pane.window_name == hub_window
        end
        return false if in_hub

        @visible_tab = nil
        true
      end
    end

    # State and actions for the global TUI: repo discovery across scan roots,
    # per-repo tmux and agent status, and the hub's agent-tab lifecycle. A
    # mutable PORO the event loop drives and the renderer reads.
    class GlobalApp
      # Cadence of the tmux-derived refresh (sessions, windows, agent states).
      TMUX_REFRESH = 3
      # Cadence of full repo re-discovery across the scan roots, in seconds.
      DISCOVERY_REFRESH = 30
      # Minimum interval between agent-focus queries to the tmux server.
      FOCUS_POLL_INTERVAL = 0.25
      # Name of the tmux window hosting a repo's TUI.
      REPO_TUI_WINDOW = "orn"

      attr_accessor :entries,
        :selected,
        :error,
        :spinner_tick
      attr_reader :config,
        :list_state,
        :hub

      # Build the app, capturing the hosting tmux pane and window for hub tabs,
      # and run an initial discovery.
      def self.build(output_mode, config)
        hub_pane = ENV.fetch("TMUX_PANE", nil)
        hub_location = hub_pane && Orn::Tmux.current_session_window(output_mode, hub_pane)
        app = new(
          output_mode: output_mode,
          config: config,
          mru_state: State.load,
          hub_pane: hub_pane,
          hub_location: hub_location
        )
        app.full_refresh
        app
      end

      def initialize(output_mode:, config:, entries: [], mru_state: nil, hub_pane: nil, hub_location: nil)
        @output = output_mode
        @config = config
        @entries = entries
        @selected = 0
        @list_state = ListState.new
        @list_state.select(0) unless entries.empty?
        @error = nil
        @spinner_tick = 0
        @hub = HubState.new(hub_pane, hub_location)
        @mru_state = mru_state || State.new
        @last_tmux_refresh = monotonic
        @last_discovery = monotonic
        @last_focus_poll = monotonic
      end

      # Re-discover repos (with MRU and expanded state reapplied), refresh
      # tmux data, and resort, keeping the selection anchored to the same row.
      def full_refresh
        anchor = selected_identity
        @entries = RepoDiscovery.discover(
          @output,
          @config,
          @mru_state
        )
        refresh_tmux_data
        RepoDiscovery.sort_entries(@entries)
        reanchor_selected(anchor)
        @last_discovery = monotonic
      end

      # Rows currently visible in the tree: every repo, plus worktrees of
      # expanded repos.
      def visible_rows
        rows = []
        @entries.each_with_index do |entry, i|
          rows << TreeRow.repo(i)
          next unless entry.expanded

          entry.worktrees.each_index { |j| rows << TreeRow.worktree(i, j) }
        end
        rows
      end

      def selected_row
        visible_rows[@selected]
      end

      # Full discovery on the slow cadence; the cheaper tmux refresh otherwise.
      def maybe_refresh
        if monotonic - @last_discovery >= DISCOVERY_REFRESH
          full_refresh
        elsif monotonic - @last_tmux_refresh >= TMUX_REFRESH
          refresh_tmux
        end
      end

      # Move the selection down the visible rows, wrapping past the end.
      def move_down
        length = visible_rows.length
        return if length.zero?

        @selected = (@selected + 1) % length
        sync_list_state
      end

      # Move the selection up the visible rows, wrapping past the start.
      def move_up
        length = visible_rows.length
        return if length.zero?

        @selected = (@selected + length - 1) % length
        sync_list_state
      end

      def sync_list_state
        @list_state.select(visible_rows.empty? ? nil : @selected)
      end

      # Toggle expansion of the selected repo (or the repo owning the selected
      # worktree row). Collapsing from a worktree row moves the selection to the
      # repo row.
      def toggle_expanded
        row = selected_row
        return unless row

        repo_idx = row.repo_index
        entry = @entries[repo_idx]
        entry.expanded = !entry.expanded
        @mru_state.set_expanded(entry.root, entry.expanded)
        @mru_state.save

        if entry.expanded
          self.class.refresh_worktree_git_stats(@output, entry)
        elsif row.worktree?
          @selected = visible_rows.index { |candidate| candidate == TreeRow.repo(repo_idx) } || 0
        end
        clamp_selected
      end

      def any_agent_working?
        @entries.any? { |entry| entry.aggregate_agent_state == :working }
      end

      # Fast poll while an agent is working so the spinner animates smoothly.
      def poll_timeout
        any_agent_working? ? FAST_POLL_TIMEOUT : POLL_TIMEOUT
      end

      def clear_error
        @error = nil
      end

      # The tab currently borrowed into the hub window, if any.
      def visible
        @hub.visible
      end

      # True while the visible tab's agent pane has tmux focus, for the
      # sidebar's emphasized indicator.
      def agent_focused?
        @hub.agent_focused
      end

      # The visible tab's index into the open-tab list, if any.
      def visible_tab
        @hub.visible_index
      end

      def tab_index_for(root, branch)
        @hub.tab_index_for(root, branch)
      end

      # Act on the selected row: switch the tmux client into a repo's session,
      # or open/focus a worktree's agent tab.
      def enter_selected
        row = selected_row
        return unless row

        if row.repo?
          enter_repo_row(row.repo_index)
        else
          open_or_focus_tab(row.repo_index, row.wt_index)
        end
      end

      # Re-apply the sidebar width; called on terminal resize while a tab is
      # visible.
      def enforce_layout
        hub_pane = @hub.hub_pane
        return unless @hub.visible_index && hub_pane

        Orn::Tmux.resize_pane_width(
          @output,
          hub_pane,
          Hub::SIDEBAR_WIDTH_PCT
        )
      rescue Orn::Error
        nil
      end

      # Track whether the visible tab's agent pane has focus, for the emphasized
      # sidebar indicator. Rate-limited so fast spinner ticks do not spawn a
      # tmux process per frame.
      def poll_focus
        location = @hub.hub_location
        tab = @hub.visible
        unless location && tab
          @hub.agent_focused = false
          return
        end
        return if monotonic - @last_focus_poll < FOCUS_POLL_INTERVAL

        hub_session, hub_window = location
        active = Orn::Tmux.active_pane(
          @output,
          hub_session,
          hub_window
        )
        @hub.agent_focused = active == tab.pane_id
        @last_focus_poll = monotonic
      end

      # Cycle the visible tab forward or backward through the open tabs.
      def cycle_tab(forward)
        next_index = Hub.cycle_index(
          @hub.tabs.length,
          @hub.visible_index,
          forward
        )
        return if next_index.nil? || @hub.visible_index == next_index

        show_tab(next_index)
        select_visible_tab_row
      end

      # Close the selected worktree row's tab, or the visible tab when the
      # selection has none. The agent keeps running in its home window.
      def close_tab
        idx = selected_tab_index || @hub.visible_index
        return unless idx

        hide_visible if @hub.visible_index == idx
        @hub.remove_tab(idx)
        Hub.remove_bindings(@output) if @hub.visible_index.nil?
      end

      # Hide and forget every tab; called when the TUI exits.
      def close_all_tabs
        hide_visible
        @hub.clear_tabs
        Hub.remove_bindings(@output)
      end

      # Move the sidebar selection onto the visible tab's worktree row,
      # expanding the owning repo when collapsed, so the highlighted row follows
      # the focused agent while cycling.
      def select_visible_tab_row
        tab = visible
        return unless tab

        repo_idx = @entries.index { |entry| entry.root.to_s == tab.root.to_s }
        return unless repo_idx

        expand_repo_for_tab(repo_idx, tab.root)
        row_idx = visible_rows.index do |row|
          row.worktree? && row.repo_index == repo_idx && @entries[repo_idx].worktrees[row.wt_index].branch == tab.branch
        end
        return unless row_idx

        @selected = row_idx
        sync_list_state
      end

      # Move `selected` back onto the row identified by `identity`, if it still
      # exists; otherwise fall back to clamping into range. Used after a resort
      # so live-session reordering does not silently move the cursor onto an
      # unrelated row.
      def reanchor_selected(identity)
        if identity
          idx = visible_rows.index { |row| row_identity(row) == identity }
          @selected = idx if idx
        end
        clamp_selected
      end

      def selected_identity
        row = selected_row
        row && row_identity(row)
      end

      def clamp_selected
        length = visible_rows.length
        @selected = length - 1 if @selected >= length && length.positive?
        sync_list_state
      end

      # Highest-priority state among panes hosting an agent (blocked > working
      # > idle), or nil when no agent is detected.
      def self.aggregate_state(states)
        agents = states.values.select(&:agent)
        return nil if agents.empty?

        agents.map(&:state).max_by { |state| Orn::Detect.state_priority(state) }
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

      # Update every repo's session, window, and agent status from one shared
      # pane listing.
      def self.refresh_tmux_state(output, repos, tab, all_panes)
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

      # Borrowing a repo's only pane can kill its session; the agent still runs
      # in the hub, so its status stays visible through the borrowed pane.
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

      # Switch the tmux client to the repo's session, creating the session and
      # its `orn` TUI window when missing.
      def self.enter_repo(output, root)
        config = Orn::Config.load(root)
        project = Orn::Git::Project.new(
          root: root,
          config: config
        )
        session_name = Orn::Session.session_name(project)
        base = config.base

        Orn::Tmux.ensure_session(
          output,
          session_name,
          root,
          base
        )
        unless Orn::Tmux.window_exists?(
          output,
          session_name,
          REPO_TUI_WINDOW
        )
          create_repo_tui_window(
            output,
            session_name,
            root
          )
        end
        Orn::TUI.reorder_windows(
          output,
          session_name,
          base
        )
        Orn::Cmd.new(output_mode: output).exec(
          "tmux",
          "switch-client",
          "-t",
          "#{session_name}:#{REPO_TUI_WINDOW}"
        )
      end

      def self.create_repo_tui_window(output, session_name, root)
        Orn::Cmd.new(output_mode: output).exec(
          "tmux",
          "new-window",
          "-a",
          "-t",
          "#{session_name}:",
          "-n",
          REPO_TUI_WINDOW,
          "-c",
          root.to_s,
          Orn::TUI.relaunch_command
        )
      end

      private

      def row_identity(row)
        entry = @entries[row.repo_index]
        if row.repo?
          RowIdentity.repo(entry.root)
        else
          RowIdentity.worktree(entry.root, entry.worktrees[row.wt_index].branch)
        end
      end

      def enter_repo_row(repo_idx)
        entry = @entries[repo_idx]
        return unless entry.healthy

        @mru_state.touch(entry.root)
        @mru_state.save
        self.class.enter_repo(@output, entry.root)
      rescue Orn::Error => e
        @error = e.message
      end

      # Open an agent tab for a worktree row. If the tab is already visible,
      # focus its agent pane; if it is open but hidden, bring it to front.
      def open_or_focus_tab(repo_idx, wt_idx)
        entry = @entries[repo_idx]
        return unless entry.healthy

        hub_pane = @hub.hub_pane
        unless hub_pane
          @error = "agent tabs require the TUI to run inside tmux"
          return
        end

        branch = entry.worktrees[wt_idx].branch
        existing = tab_index_for(entry.root, branch)
        return focus_existing_tab(existing) if existing

        open_new_tab(
          entry,
          branch,
          hub_pane
        )
      end

      def focus_existing_tab(idx)
        if @hub.visible_index == idx
          tab = visible
          begin
            Orn::Tmux.select_pane(@output, tab.pane_id) if tab
          rescue Orn::Error
            nil
          end
        else
          show_tab(idx)
        end
      end

      def open_new_tab(entry, branch, hub_pane)
        hide_visible
        @mru_state.touch(entry.root)
        @mru_state.save
        tab = Hub.open_tab(
          @output,
          root: entry.root,
          session: entry.session_name,
          base_branch: entry.base_branch,
          branch: branch,
          hub_pane: hub_pane
        )
        idx = @hub.push_tab(tab)
        @hub.visible_index = idx
        install_bindings_for_visible
        refresh_tmux
      rescue Orn::Error => e
        @error = e.message
      end

      # Bring a hidden tab to front: hide the visible one, borrow this tab's
      # pane. Drops the tab if its pane is gone.
      def show_tab(idx)
        hub_pane = @hub.hub_pane
        return unless hub_pane

        hide_visible
        tab = @hub.tabs[idx]
        Hub.show_tab(
          @output,
          tab,
          hub_pane
        )
        @hub.visible_index = idx
        install_bindings_for_visible
        refresh_tmux
      rescue Orn::Error => e
        @error = e.message
        @hub.remove_tab(idx)
      end

      # Hide the visible tab's pane (returns home); the tab stays open.
      def hide_visible
        idx = @hub.take_visible
        return unless idx

        Hub.hide_tab(@output, @hub.tabs[idx])
      rescue Orn::Error => e
        @error = e.message
      end

      def install_bindings_for_visible
        location = @hub.hub_location
        hub_pane = @hub.hub_pane
        tab = visible
        return unless location && hub_pane && tab

        hub_session, hub_window = location
        Hub.install_bindings(
          @output,
          hub_session,
          hub_window,
          hub_pane,
          tab.pane_id
        )
      rescue Orn::Error => e
        @error = e.message
      end

      def selected_tab_index
        row = selected_row
        return nil unless row&.worktree?

        entry = @entries[row.repo_index]
        tab_index_for(entry.root, entry.worktrees[row.wt_index].branch)
      end

      def expand_repo_for_tab(repo_idx, root)
        entry = @entries[repo_idx]
        return if entry.expanded

        entry.expanded = true
        @mru_state.set_expanded(root, true)
        @mru_state.save
        self.class.refresh_worktree_git_stats(@output, entry)
      end

      # Refresh tmux-derived state and resort, keeping the selection anchored to
      # the same row rather than the same index.
      def refresh_tmux
        anchor = selected_identity
        refresh_tmux_data
        reanchor_selected(anchor)
      end

      # Reconcile tabs against a fresh pane listing, then refresh per-repo tmux
      # state and resort.
      def refresh_tmux_data
        # A failed listing means "no information", not "no panes": pruning tabs
        # against it would drop live tabs, strand their borrowed panes in the
        # hub, and tear down the key bindings.
        all_panes = Orn::Tmux.list_all_panes_metadata(@output)
        unless all_panes
          @last_tmux_refresh = monotonic
          return
        end
        prune_dead_tabs(all_panes)
        sync_visible_with_reality(all_panes)
        self.class.refresh_tmux_state(
          @output,
          @entries,
          visible,
          all_panes
        )
        RepoDiscovery.sort_entries(@entries)
        @last_tmux_refresh = monotonic
      end

      def prune_dead_tabs(all_panes)
        Hub.remove_bindings(@output) if @hub.prune_dead_tabs(all_panes)
      end

      def sync_visible_with_reality(all_panes)
        Hub.remove_bindings(@output) if @hub.demote_visible_if_moved(all_panes)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
