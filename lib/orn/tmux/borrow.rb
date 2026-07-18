# frozen_string_literal: true

module Orn
  module Tmux
    # Primitives for borrowing panes into the TUI hub window and returning them
    # home. tui/hub builds the higher-level tab mechanics on top of these.

    # Pane user option names used to tag borrowed panes. Stored in the tmux
    # server so bookkeeping survives an orn crash. Namespaced to orn; nothing
    # else reads them.
    OPT_HOME_SESSION = "@orn_home_session"
    OPT_HOME_WINDOW = "@orn_home_window"

    # A pane currently borrowed into a hub window, identified by its tags.
    BorrowedPane = Data.define(:pane_id, :home_session, :home_window)

    # Move `src_pane` into a horizontal split of `dst`, giving it `percentage`%
    # of the width. `dst` is any tmux target (pane id or session:window). When
    # `focus` is false the client's active pane is left unchanged.
    def self.join_pane(output_mode, src_pane, dst, percentage, focus)
      args = ["join-pane", "-h"]
      args << "-d" unless focus
      args.push("-s", src_pane, "-t", dst, "-l", "#{percentage}%")
      tmux_exec(output_mode, *args)
    end

    # Break `src_pane` out into a new window named `name` at the end of
    # `session`, without switching to it.
    def self.break_pane(output_mode, src_pane, session, name)
      # Trailing colon forces session interpretation: a bare name is a
      # target-window, which tmux first matches against window names in the
      # caller's current session.
      target = "#{session}:"
      tmux_exec(output_mode, "break-pane", "-d", "-s", src_pane, "-n", name, "-t", target)
    end

    # Recreate a session that was destroyed when `pane` was borrowed out of its
    # only window's only pane, then move `pane` back into it as window `name`.
    # tmux kills a session once its last pane is gone, so plain break-pane
    # cannot target it; a placeholder session is created first and torn down
    # once the real window is back in place.
    def self.recreate_session_with_pane(output_mode, pane, session, name)
      cwd = pane_current_path(output_mode, pane)
      raise Orn::Error, "cannot determine cwd of pane #{pane}" if cwd.nil?

      result = tmux_run(output_mode, "new-session", "-d", "-s", session, "-c", cwd, "-P", "-F", "\#{window_id}")
      placeholder = result.stdout.strip
      break_pane(output_mode, pane, session, name)
      tmux_exec(output_mode, "kill-window", "-t", placeholder)
    end

    # Make `pane` the active pane of its window.
    def self.select_pane(output_mode, pane)
      tmux_exec(output_mode, "select-pane", "-t", pane)
    end

    # Resize a pane to an absolute percentage of the window width.
    def self.resize_pane_width(output_mode, pane, percentage)
      tmux_exec(output_mode, "resize-pane", "-t", pane, "-x", "#{percentage}%")
    end

    # Set a pane-scoped user option (name must start with '@').
    def self.set_pane_option(output_mode, pane, name, value)
      tmux_exec(output_mode, "set-option", "-p", "-t", pane, name, value)
    end

    # Unset a pane-scoped user option.
    def self.unset_pane_option(output_mode, pane, name)
      tmux_exec(output_mode, "set-option", "-p", "-u", "-t", pane, name)
    end

    # All panes tagged as borrowed, across every session.
    def self.list_borrowed_panes(output_mode)
      # \#{pane_id}<TAB>\#{@orn_home_session}<TAB>\#{@orn_home_window}: the outer
      # \#{...} are literal tmux tokens; the inner #{OPT_*} interpolate the
      # option names.
      format = "\#{pane_id}\t\#{#{OPT_HOME_SESSION}}\t\#{#{OPT_HOME_WINDOW}}"
      result = tmux_output(output_mode, "list-panes", "-a", "-F", format)
      return [] unless result&.success?

      parse_borrowed_lines(result.stdout)
    end

    # Keep only lines with both home tags set; untagged panes list the options
    # as empty fields.
    def self.parse_borrowed_lines(output)
      output.lines.filter_map do |line|
        # split(-1) keeps trailing empty fields so an untagged pane still yields
        # three fields (two empty) rather than being silently truncated.
        fields = line.chomp.split("\t", -1)
        next unless fields.length == 3

        pane_id, home_session, home_window = fields
        next if home_session.empty? || home_window.empty?

        BorrowedPane.new(
          pane_id: pane_id,
          home_session: home_session,
          home_window: home_window
        )
      end
    end

    # The active pane id in a window, if the window exists.
    def self.active_pane(output_mode, session, window)
      target = window_target(session, window)
      result = tmux_output(output_mode, "list-panes", "-t", target, "-F", "\#{pane_id}\t\#{?pane_active,1,0}")
      return nil unless result&.success?

      active_line = result.stdout.lines.map(&:chomp).find { |line| line.end_with?("\t1") }
      active_line&.split("\t")&.first
    end

    # The session and window containing `pane`. Targets the pane explicitly so
    # it works without an attached client (e.g. a detached test server).
    def self.current_session_window(output_mode, pane)
      result = tmux_output(output_mode, "display-message", "-p", "-t", pane, "\#{session_name}\t\#{window_name}")
      return nil unless result&.success?

      session, window = result.stdout.strip.split("\t", 2)
      return nil if window.nil?

      [session, window]
    end

    # A tmux format condition that is truthy only for `window` in `session`.
    # Used to scope root-table key bindings to the hub window.
    def self.window_guard_condition(session, window)
      "\#{&&:\#{==:\#{session_name},#{session}},\#{==:\#{window_name},#{window}}}"
    end

    # Bind `key` in the root table (no prefix), guarded by a tmux format
    # `condition`: when truthy the binding runs `action`, otherwise the key is
    # re-sent to the active pane so other windows are unaffected.
    def self.bind_key_guarded(output_mode, key, condition, action)
      fallthrough = "send-keys #{key}"
      tmux_exec(output_mode, "bind-key", "-n", key, "if-shell", "-F", condition, action, fallthrough)
    end

    # Remove a root-table key binding installed by bind_key_guarded.
    def self.unbind_key(output_mode, key)
      tmux_exec(output_mode, "unbind-key", "-n", key)
    end

    # The current working directory of a pane's shell. Used to recreate a
    # session that borrowing destroyed, at the pane's original path.
    def self.pane_current_path(output_mode, pane)
      result = tmux_output(output_mode, "display-message", "-p", "-t", pane, "\#{pane_current_path}")
      return nil unless result&.success?

      path = result.stdout.strip
      path.empty? ? nil : path
    end

    private_class_method :pane_current_path
  end
end
