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

    # State and actions for the global TUI: the selection over the repo tree
    # and the refresh cadence. Repo scanning lives in RepoDiscovery, live
    # tmux/agent status in RepoStatus, and the agent-tab lifecycle in Tabs;
    # this class composes them. A mutable PORO the event loop drives and the
    # renderer reads.
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
        :tabs

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

      # `tabs` can be injected (specs pair it with a fake tmux-effects layer);
      # by default the app builds its own, reporting tab errors onto the
      # error line.
      def initialize(output_mode:, config:, entries: [], mru_state: nil, hub_pane: nil, hub_location: nil, tabs: nil)
        @output = output_mode
        @config = config
        @entries = entries
        @selected = 0
        @list_state = ListState.new
        @list_state.select(0) unless entries.empty?
        @error = nil
        @spinner_tick = 0
        @tabs = tabs || Tabs.new(
          output_mode: output_mode,
          hub_pane: hub_pane,
          hub_location: hub_location,
          on_error: ->(message) { @error = message }
        )
        @mru_state = mru_state || State.new
        @last_tmux_refresh = monotonic
        @last_discovery = monotonic
        @last_focus_poll = monotonic
      end

      # Re-discover repos (with MRU and expanded state reapplied), refresh
      # tmux data, and resort, keeping the selection anchored to the same row.
      def full_refresh
        anchor = selected_identity
        @entries = RepoDiscovery.discover(@output, @config, @mru_state)
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
        entry = @entries[repo_idx].with(expanded: !@entries[repo_idx].expanded)
        @entries[repo_idx] = entry
        @mru_state.set_expanded(entry.root, entry.expanded)
        @mru_state.save

        if entry.expanded
          @entries[repo_idx] = RepoStatus.with_worktree_git_stats(@output, entry)
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
        hub_pane = @tabs.hub_pane
        return unless @tabs.visible_index && hub_pane

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
        location = @tabs.hub_location
        tab = @tabs.visible
        unless location && tab
          @tabs.agent_focused = false
          return
        end
        return if monotonic - @last_focus_poll < FOCUS_POLL_INTERVAL

        hub_session, hub_window = location
        active = Orn::Tmux.active_pane(
          @output,
          hub_session,
          hub_window
        )
        @tabs.agent_focused = active == tab.pane_id
        @last_focus_poll = monotonic
      end

      # Cycle the visible tab forward or backward through the open tabs.
      def cycle_tab(forward)
        return unless @tabs.cycle(forward)

        refresh_tmux
        select_visible_tab_row
      end

      # Close the selected worktree row's tab, or the visible tab when the
      # selection has none. The agent keeps running in its home window.
      def close_tab
        idx = selected_tab_index || @tabs.visible_index
        return unless idx

        @tabs.close(idx)
      end

      # Hide and forget every tab; called when the TUI exits.
      def close_all_tabs
        @tabs.close_all
      end

      # Move the sidebar selection onto the visible tab's worktree row,
      # expanding the owning repo when collapsed, so the highlighted row follows
      # the focused agent while cycling.
      def select_visible_tab_row
        tab = @tabs.visible
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

        unless @tabs.hub_pane
          @error = "agent tabs require the TUI to run inside tmux"
          return
        end

        branch = entry.worktrees[wt_idx].branch
        existing = @tabs.tab_index_for(entry.root, branch)
        return focus_existing_tab(existing) if existing

        open_new_tab(entry, branch)
      end

      def focus_existing_tab(idx)
        return show_tab(idx) unless @tabs.visible_index == idx

        tab = @tabs.visible
        begin
          Orn::Tmux.select_pane(@output, tab.pane_id) if tab
        rescue Orn::Error
          nil
        end
      end

      def open_new_tab(entry, branch)
        @mru_state.touch(entry.root)
        @mru_state.save
        opened = @tabs.open(
          root: entry.root,
          session: entry.session_name,
          base_branch: entry.base_branch,
          branch: branch
        )
        refresh_tmux if opened
      end

      def show_tab(idx)
        refresh_tmux if @tabs.show(idx)
      end

      def selected_tab_index
        row = selected_row
        return nil unless row&.worktree?

        entry = @entries[row.repo_index]
        @tabs.tab_index_for(entry.root, entry.worktrees[row.wt_index].branch)
      end

      def expand_repo_for_tab(repo_idx, root)
        entry = @entries[repo_idx]
        return if entry.expanded

        @mru_state.set_expanded(root, true)
        @mru_state.save
        @entries[repo_idx] = RepoStatus.with_worktree_git_stats(@output, entry.with(expanded: true))
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
        @tabs.prune_dead_tabs(all_panes)
        @tabs.demote_visible_if_moved(all_panes)
        @entries = RepoStatus.refresh(
          @output,
          @entries,
          @tabs.visible,
          all_panes
        )
        RepoDiscovery.sort_entries(@entries)
        @last_tmux_refresh = monotonic
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
