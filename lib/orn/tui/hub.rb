# frozen_string_literal: true

module Orn
  module TUI
    # Agent tab mechanics for the global TUI hub window.
    #
    # An agent "tab" borrows the real tmux pane running a worktree's agent into
    # the hub window beside the sidebar (33/67 split), and returns it to its
    # home window on hide. Borrowed panes are tagged with pane user options in
    # the tmux server so a crashed TUI can reconcile on next start.
    module Hub
      SIDEBAR_WIDTH_PCT = 33
      AGENT_WIDTH_PCT = 67
      # Hub binding: refocus the sidebar (TUI) pane.
      KEY_FOCUS_SIDEBAR = "M-o"
      # Hub binding: focus the visible tab's agent pane.
      KEY_FOCUS_AGENT = "M-i"
      # Hub binding: cycle to the next open tab.
      KEY_CYCLE_NEXT = "M-n"
      # Hub binding: cycle to the previous open tab.
      KEY_CYCLE_PREV = "M-p"
      # Sidebar keys the cycle bindings forward to the TUI pane.
      CYCLE_NEXT_INPUT = "n"
      CYCLE_PREV_INPUT = "p"

      # An open agent tab: a worktree's agent pane currently borrowed into the
      # hub window.
      Tab = Data.define(:root, :session, :base_branch, :branch, :pane_id)

      # Borrow the agent pane of `branch` into the hub window. Creates the
      # worktree window (booting its configured layout, including the agent)
      # when it does not exist yet. Raises when the branch is sandboxed and
      # closed (its reopen flow can prompt) or when no agent pane is found.
      def self.open_tab(output_mode, root:, session:, base_branch:, branch:, hub_pane:)
        ensure_window(output_mode, root, branch, session)

        panes = Orn::Tmux.list_panes_metadata(output_mode, session)
        pane = Orn::Detect.choose_agent_pane(panes, branch)
        raise Orn::Error, "no pane found for '#{branch}' in session '#{session}'" unless pane

        tab = Tab.new(
          root: root,
          session: session,
          base_branch: base_branch,
          branch: branch,
          pane_id: pane.pane_id
        )
        show_tab(output_mode, tab, hub_pane)
        tab
      end

      # Open the worktree window if closed, refusing a sandboxed worktree whose
      # reopen must go through `orn switch` (it can prompt, so it cannot run
      # under the TUI screen).
      def self.ensure_window(output_mode, root, branch, session)
        return if Orn::Tmux.window_exists?(output_mode, session, branch)

        project = Orn::Git::Project.new(root: root, config: Orn::Config.load(root))
        sbx_name = project.sandbox_name(branch)
        if Orn::Sandbox.exists?(output_mode, sbx_name)
          raise Orn::Error,
            "'#{branch}' uses sandbox '#{sbx_name}' and its window is closed; " \
            "run 'orn switch #{branch}' to reopen it"
        end
        Orn::Tmux.open_window_non_interactive(output_mode, project, branch)
      end

      # Borrow an already-known tab pane into the hub window (used both on first
      # open and when re-showing a hidden tab).
      def self.show_tab(output_mode, tab, hub_pane)
        Orn::Tmux.set_pane_option(output_mode, tab.pane_id, Orn::Tmux::OPT_HOME_SESSION, tab.session)
        Orn::Tmux.set_pane_option(output_mode, tab.pane_id, Orn::Tmux::OPT_HOME_WINDOW, tab.branch)
        Orn::Tmux.join_pane(output_mode, tab.pane_id, hub_pane, AGENT_WIDTH_PCT, true)
        Orn::Tmux.resize_pane_width(output_mode, hub_pane, SIDEBAR_WIDTH_PCT)
      end

      # Return a tab's pane to its home window and restore window order there.
      def self.hide_tab(output_mode, tab)
        borrowed = Orn::Tmux::BorrowedPane.new(
          pane_id: tab.pane_id,
          home_session: tab.session,
          home_window: tab.branch
        )
        return_pane_home(output_mode, borrowed)
        Orn::TUI.reorder_windows(output_mode, tab.session, tab.base_branch)
      end

      # Return a borrowed pane to its home window, recreating the window (and,
      # if borrowing it emptied the whole session, the session itself) when
      # needed.
      def self.return_pane_home(output_mode, borrowed)
        if Orn::Tmux.window_exists?(output_mode, borrowed.home_session, borrowed.home_window)
          target = "#{borrowed.home_session}:#{borrowed.home_window}"
          Orn::Tmux.join_pane(output_mode, borrowed.pane_id, target, 50, false)
        elsif Orn::Session.session_exists?(output_mode, borrowed.home_session)
          Orn::Tmux.break_pane(output_mode, borrowed.pane_id, borrowed.home_session, borrowed.home_window)
        else
          # Borrowing the only pane of the only window in home_session kills the
          # session outright, so there is nothing left to break-pane into.
          Orn::Tmux.recreate_session_with_pane(
            output_mode, borrowed.pane_id, borrowed.home_session, borrowed.home_window
          )
        end
        Orn::Tmux.unset_pane_option(output_mode, borrowed.pane_id, Orn::Tmux::OPT_HOME_SESSION)
        Orn::Tmux.unset_pane_option(output_mode, borrowed.pane_id, Orn::Tmux::OPT_HOME_WINDOW)
      end

      # Return every tagged pane home. Run at TUI startup so panes stranded by a
      # crashed or killed TUI land back in their worktree windows.
      def self.reconcile(output_mode)
        Orn::Tmux.list_borrowed_panes(output_mode).each do |borrowed|
          return_pane_home(output_mode, borrowed)
        rescue Orn::Error
          nil
        end
      end

      # Return the borrowed pane for a branch, if any. Used by `orn switch`,
      # `orn remove`, and the project TUI so acting on a worktree whose agent is
      # tabbed into the hub does not spawn a duplicate window or orphan the pane.
      def self.return_borrowed_for_branch(output_mode, session, branch)
        borrowed = Orn::Tmux.list_borrowed_panes(output_mode).find do |pane|
          pane.home_session == session && pane.home_window == branch
        end
        return false unless borrowed

        begin
          return_pane_home(output_mode, borrowed)
          true
        rescue Orn::Error
          false
        end
      end

      # Install the guarded key bindings for the hub window. `M-o` refocuses the
      # sidebar, `M-i` the visible tab's agent pane, and `M-n`/`M-p` forward a
      # cycle keypress to the TUI pane (which owns the tab list). Outside the hub
      # window all keys pass through untouched.
      def self.install_bindings(output_mode, hub_session, hub_window, hub_pane, agent_pane)
        condition = Orn::Tmux.window_guard_condition(hub_session, hub_window)
        cycle_next = "send-keys -t #{hub_pane} #{CYCLE_NEXT_INPUT}"
        cycle_prev = "send-keys -t #{hub_pane} #{CYCLE_PREV_INPUT}"
        Orn::Tmux.bind_key_guarded(output_mode, KEY_FOCUS_SIDEBAR, condition, "select-pane -t #{hub_pane}")
        Orn::Tmux.bind_key_guarded(output_mode, KEY_FOCUS_AGENT, condition, "select-pane -t #{agent_pane}")
        Orn::Tmux.bind_key_guarded(output_mode, KEY_CYCLE_NEXT, condition, cycle_next)
        Orn::Tmux.bind_key_guarded(output_mode, KEY_CYCLE_PREV, condition, cycle_prev)
      end

      # Unbind every hub key binding; failures are ignored.
      def self.remove_bindings(output_mode)
        [KEY_FOCUS_SIDEBAR, KEY_FOCUS_AGENT, KEY_CYCLE_NEXT, KEY_CYCLE_PREV].each do |key|
          Orn::Tmux.unbind_key(output_mode, key)
        rescue Orn::Error
          nil
        end
      end

      # True when the tab's pane still exists somewhere in the tmux server.
      def self.tab_pane_alive(tab, all_panes)
        all_panes.any? { |pane| pane.pane_id == tab.pane_id }
      end

      # The tab index reached by cycling forward or backward from `current`
      # (nil when no tab is visible); nil when there are no tabs.
      def self.cycle_index(length, current, forward)
        return nil if length.zero?

        if current.nil?
          forward ? 0 : length - 1
        elsif forward
          (current + 1) % length
        else
          (current + length - 1) % length
        end
      end

      # The visible-tab index after removing the tab at `removed`.
      def self.adjust_visible_after_remove(visible, removed)
        return visible if visible.nil?
        return nil if visible == removed

        visible > removed ? visible - 1 : visible
      end
    end
  end
end
