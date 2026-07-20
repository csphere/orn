# frozen_string_literal: true

module Orn
  module Tmux
    # Primitives for borrowing panes into the TUI hub window and returning
    # them home, plus the guarded root-table key bindings the hub installs.
    # tui/hub builds the higher-level tab mechanics on top of these.
    class Client
      # Move `src_pane` into a horizontal split of `dst`, giving it
      # `percentage`% of the width. `dst` is any tmux target (pane id or
      # session:window). When `focus` is false the client's active pane is
      # left unchanged.
      def join_pane(src_pane, dst, percentage, focus)
        args = ["join-pane", "-h"]
        args << "-d" unless focus
        args.push(
          "-s",
          src_pane,
          "-t",
          dst,
          "-l",
          "#{percentage}%"
        )
        tmux_exec(*args)
      end

      # Break `src_pane` out into a new window named `name` at the end of
      # `session`, without switching to it.
      def break_pane(src_pane, session, name)
        tmux_exec("break-pane", "-d", "-s", src_pane, "-n", name, "-t", session_target(session))
      end

      # Recreate a session that was destroyed when `pane` was borrowed out of
      # its only window's only pane, then move `pane` back into it as window
      # `name`. tmux kills a session once its last pane is gone, so plain
      # break-pane cannot target it; a placeholder session is created first
      # and torn down once the real window is back in place.
      def recreate_session_with_pane(pane, session, name)
        cwd = pane_current_path(pane)
        raise Orn::Error, "cannot determine cwd of pane #{pane}" if cwd.nil?

        result = tmux_run(
          "new-session",
          "-d",
          "-s",
          session,
          "-c",
          cwd,
          "-P",
          "-F",
          "\#{window_id}"
        )
        placeholder = result.stdout.strip
        break_pane(
          pane,
          session,
          name
        )
        tmux_exec("kill-window", "-t", placeholder)
      end

      # Make `pane` the active pane of its window.
      def select_pane(pane)
        tmux_exec("select-pane", "-t", pane)
      end

      # Resize a pane to an absolute percentage of the window width.
      def resize_pane_width(pane, percentage)
        tmux_exec("resize-pane", "-t", pane, "-x", "#{percentage}%")
      end

      # Set a pane-scoped user option (name must start with '@').
      def set_pane_option(pane, name, value)
        tmux_exec("set-option", "-p", "-t", pane, name, value)
      end

      # Unset a pane-scoped user option.
      def unset_pane_option(pane, name)
        tmux_exec("set-option", "-p", "-u", "-t", pane, name)
      end

      # All panes tagged as borrowed, across every session.
      def list_borrowed_panes
        # \#{pane_id}<TAB>\#{@orn_home_session}<TAB>\#{@orn_home_window}: the
        # outer \#{...} are literal tmux tokens; the inner #{OPT_*} interpolate
        # the option names.
        format = "\#{pane_id}\t\#{#{OPT_HOME_SESSION}}\t\#{#{OPT_HOME_WINDOW}}"
        result = tmux_output(
          "list-panes",
          "-a",
          "-F",
          format
        )
        return [] unless result&.success?

        Tmux.parse_borrowed_lines(result.stdout)
      end

      # The active pane id in a window, if the window exists.
      def active_pane(session, window)
        target = Tmux.window_target(session, window)
        result = tmux_output(
          "list-panes",
          "-t",
          target,
          "-F",
          "\#{pane_id}\t\#{?pane_active,1,0}"
        )
        return nil unless result&.success?

        active_line = result.stdout.lines.map(&:chomp).find { |line| line.end_with?("\t1") }
        active_line&.split("\t")&.first
      end

      # The session and window containing `pane`. Targets the pane explicitly
      # so it works without an attached client (e.g. a detached test server).
      def current_session_window(pane)
        result = tmux_output(
          "display-message",
          "-p",
          "-t",
          pane,
          "\#{session_name}\t\#{window_name}"
        )
        return nil unless result&.success?

        session, window = result.stdout.strip.split("\t", 2)
        return nil if window.nil?

        [session, window]
      end

      # Bind `key` in the root table (no prefix), guarded by a tmux format
      # `condition`: when truthy the binding runs `action`, otherwise the key
      # is re-sent to the active pane so other windows are unaffected.
      def bind_key_guarded(key, condition, action)
        fallthrough = "send-keys #{key}"
        tmux_exec("bind-key", "-n", key, "if-shell", "-F", condition, action, fallthrough)
      end

      # Remove a root-table key binding installed by bind_key_guarded.
      def unbind_key(key)
        tmux_exec("unbind-key", "-n", key)
      end

      private

      # The current working directory of a pane's shell. Used to recreate a
      # session that borrowing destroyed, at the pane's original path.
      def pane_current_path(pane)
        result = tmux_output(
          "display-message",
          "-p",
          "-t",
          pane,
          "\#{pane_current_path}"
        )
        return nil unless result&.success?

        path = result.stdout.strip
        path.empty? ? nil : path
      end
    end
  end
end
