# frozen_string_literal: true

module Orn
  module TUI
    # The tmux effects behind the global TUI's agent tabs (the tab list itself
    # lives in Tabs).
    #
    # An agent "tab" borrows the real tmux pane running a worktree's agent into
    # the hub window beside the sidebar (33/67 split), and returns it to its
    # home window on hide. Borrowed panes are tagged with pane user options in
    # the tmux server so a crashed TUI can reconcile on next start. The
    # reconcile helpers are also used by `orn switch`, `orn remove`, and the
    # project TUI.
    class Hub
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
      Tab = Data.define(
        :root,
        :session,
        :base_branch,
        :branch,
        :pane_id
      )

      def initialize(client:)
        @client = client
      end

      # Borrow the agent pane of `branch` into the hub window. Creates the
      # worktree window (booting its configured layout, including the agent)
      # when it does not exist yet. Raises when the branch is sandboxed and
      # closed (its reopen flow can prompt) or when no agent pane is found.
      def open_tab(root:, session:, base_branch:, branch:, hub_pane:)
        ensure_window(
          root,
          branch,
          session
        )

        panes = @client.list_panes_metadata(session)
        pane = Orn::Detect.choose_agent_pane(panes, branch)
        raise Orn::Error, "no pane found for '#{branch}' in session '#{session}'" unless pane

        tab = Tab.new(
          root: root,
          session: session,
          base_branch: base_branch,
          branch: branch,
          pane_id: pane.pane_id
        )
        show_tab(tab, hub_pane)
        tab
      end

      # Open the worktree window if closed, refusing a sandboxed worktree whose
      # reopen must go through `orn switch` (it can prompt, so it cannot run
      # under the TUI screen).
      def ensure_window(root, branch, session)
        return if @client.window_exists?(session, branch)

        project = Orn::Git::Project.new(
          root: root,
          config: Orn::Config.load(root)
        )
        sbx_name = project.sandbox_name(branch)
        if Orn::Sandbox::SbxCli.exists?(@client.output_mode, sbx_name)
          raise Orn::Error,
            "'#{branch}' uses sandbox '#{sbx_name}' and its window is closed; " \
              "run 'orn switch #{branch}' to reopen it"
        end
        @client.open_window_non_interactive(project, branch)
      end

      # Borrow an already-known tab pane into the hub window (used both on first
      # open and when re-showing a hidden tab).
      def show_tab(tab, hub_pane)
        @client.set_pane_option(
          tab.pane_id,
          Orn::Tmux::OPT_HOME_SESSION,
          tab.session
        )
        @client.set_pane_option(
          tab.pane_id,
          Orn::Tmux::OPT_HOME_WINDOW,
          tab.branch
        )
        @client.join_pane(
          tab.pane_id,
          hub_pane,
          AGENT_WIDTH_PCT,
          true
        )
        @client.resize_pane_width(hub_pane, SIDEBAR_WIDTH_PCT)
      end

      # Return a tab's pane to its home window and restore window order there.
      def hide_tab(tab)
        borrowed = Orn::Tmux::BorrowedPane.new(
          pane_id: tab.pane_id,
          home_session: tab.session,
          home_window: tab.branch
        )
        return_pane_home(borrowed)
        @client.reorder_windows(tab.session, tab.base_branch)
      end

      # Return a borrowed pane to its home window, recreating the window (and,
      # if borrowing it emptied the whole session, the session itself) when
      # needed.
      def return_pane_home(borrowed)
        if @client.window_exists?(borrowed.home_session, borrowed.home_window)
          target = "#{borrowed.home_session}:#{borrowed.home_window}"
          @client.join_pane(
            borrowed.pane_id,
            target,
            50,
            false
          )
        elsif @client.session_exists?(borrowed.home_session)
          @client.break_pane(
            borrowed.pane_id,
            borrowed.home_session,
            borrowed.home_window
          )
        else
          # Borrowing the only pane of the only window in home_session kills the
          # session outright, so there is nothing left to break-pane into.
          @client.recreate_session_with_pane(
            borrowed.pane_id,
            borrowed.home_session,
            borrowed.home_window
          )
        end
        @client.unset_pane_option(borrowed.pane_id, Orn::Tmux::OPT_HOME_SESSION)
        @client.unset_pane_option(borrowed.pane_id, Orn::Tmux::OPT_HOME_WINDOW)
      end

      # Return every tagged pane home. Run at TUI startup so panes stranded by a
      # crashed or killed TUI land back in their worktree windows.
      def reconcile
        @client.list_borrowed_panes.each do |borrowed|
          return_pane_home(borrowed)
        rescue Orn::Error
          nil
        end
      end

      # Return the borrowed pane for a branch, if any. Used by `orn switch`,
      # `orn remove`, and the project TUI so acting on a worktree whose agent is
      # tabbed into the hub does not spawn a duplicate window or orphan the pane.
      def return_borrowed_for_branch(session, branch)
        borrowed = @client.list_borrowed_panes.find do |pane|
          pane.home_session == session && pane.home_window == branch
        end
        return false unless borrowed

        begin
          return_pane_home(borrowed)
          true
        rescue Orn::Error
          false
        end
      end

      # Install the guarded key bindings for the hub window. `M-o` refocuses the
      # sidebar, `M-i` the visible tab's agent pane, and `M-n`/`M-p` forward a
      # cycle keypress to the TUI pane (which owns the tab list). Outside the hub
      # window all keys pass through untouched.
      def install_bindings(hub_session, hub_window, hub_pane, agent_pane)
        condition = Orn::Tmux.window_guard_condition(hub_session, hub_window)
        cycle_next = "send-keys -t #{hub_pane} #{CYCLE_NEXT_INPUT}"
        cycle_prev = "send-keys -t #{hub_pane} #{CYCLE_PREV_INPUT}"
        @client.bind_key_guarded(
          KEY_FOCUS_SIDEBAR,
          condition,
          "select-pane -t #{hub_pane}"
        )
        @client.bind_key_guarded(
          KEY_FOCUS_AGENT,
          condition,
          "select-pane -t #{agent_pane}"
        )
        @client.bind_key_guarded(
          KEY_CYCLE_NEXT,
          condition,
          cycle_next
        )
        @client.bind_key_guarded(
          KEY_CYCLE_PREV,
          condition,
          cycle_prev
        )
      end

      # Unbind every hub key binding; failures are ignored.
      def remove_bindings
        [KEY_FOCUS_SIDEBAR, KEY_FOCUS_AGENT, KEY_CYCLE_NEXT, KEY_CYCLE_PREV].each do |key|
          @client.unbind_key(key)
        rescue Orn::Error
          nil
        end
      end
    end
  end
end
