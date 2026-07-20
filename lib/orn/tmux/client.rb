# frozen_string_literal: true

module Orn
  module Tmux
    # Name and last-activity time of a live tmux session.
    SessionInfo = Data.define(:name, :activity)

    # The tmux domain interface: one instance per output mode, and every tmux
    # invocation in orn goes through an instance's verbs. Session and window
    # verbs live here; pane, borrowing, and trust-gated window-opening verbs
    # are defined in the client_*.rb files reopening this class.
    class Client
      # Exposed for collaborators that shell out to non-tmux tools (e.g. the
      # sandbox CLI) in the middle of a tmux flow.
      attr_reader :output_mode

      def initialize(output_mode:)
        @output_mode = output_mode
        @cmd = Orn::Cmd.new(output_mode: output_mode)
      end

      # Create `session` detached and rooted at `path` if it does not already
      # exist; its seed window is named `default_window_name` when given.
      def ensure_session(session, path, default_window_name = nil)
        return if session_exists?(session)

        args = ["new-session", "-d", "-s", session]
        args.push("-n", default_window_name) if default_window_name
        args.push("-c", path.to_s)
        tmux_exec(*args)
      end

      # Whether a tmux session named `session` currently exists.
      def session_exists?(session)
        result = tmux_output(
          "has-session",
          "-t",
          session
        )
        result ? result.success? : false
      end

      # The session name of the attached tmux client, or nil when not running
      # inside tmux or on any tmux error.
      def client_session
        return nil unless ENV.key?("TMUX")

        # The escaped \#{...} is a literal tmux format string, not Ruby interpolation.
        result = tmux_output(
          "display-message",
          "-p",
          "\#{client_session}"
        )
        return nil unless result&.success?

        name = result.stdout.strip
        name.empty? ? nil : name
      end

      # The canonicalized #{session_path} of `session`, used to tell which
      # project directory an existing session belongs to.
      def session_path(session)
        # "\#{session_path}" is a literal tmux format string.
        result = tmux_output(
          "display-message",
          "-t",
          session_target(session),
          "-p",
          "\#{session_path}"
        )
        return nil unless result&.success?

        path = result.stdout.strip
        return nil if path.empty?

        safe_realpath(path)
      end

      # Every live session's name and last-activity time; empty when no server
      # is running or the listing fails.
      def list_sessions
        result = tmux_output(
          "list-sessions",
          "-F",
          "\#{session_name}\t\#{session_activity}"
        )
        return [] unless result&.success?

        result.stdout.lines.filter_map do |line|
          name, activity = line.chomp.split("\t", 2)
          activity && SessionInfo.new(
            name: name,
            activity: activity.to_i
          )
        end
      end

      # Switch the attached tmux client to `window` in `session`.
      def switch_client(session, window)
        tmux_exec(
          "switch-client",
          "-t",
          Tmux.window_target(session, window)
        )
      end

      # Create window `name` in `session` (creating the session if needed),
      # realize `layout` by splitting panes, then run each configured pane
      # command once its shell is ready. Selects the window when done.
      def create_window(session, name, path, layout, template_vars: {}, default_window_name: nil)
        Tmux.warn_if_old_tmux

        first_pane = create_first_pane(
          session,
          name,
          path,
          default_window_name
        )
        target = Tmux.window_target(session, name)

        if layout_empty?(layout)
          tmux_exec("select-window", "-t", target)
          return
        end

        plan = layout.columns? ? Layout.plan_columns(layout.columns) : Layout.plan_rows(layout.rows)
        pane_ids = realize_splits(
          plan,
          first_pane,
          path
        )
        run_pane_commands(
          plan,
          pane_ids,
          template_vars
        )

        tmux_exec("select-pane", "-t", pane_ids[plan.focus_pane])
        tmux_exec("select-window", "-t", target)
      end

      # Add a window named `name` to `session` running `command` in `path`,
      # without selecting it. Used to host TUI processes.
      def new_window_running(session, name, path, command)
        tmux_exec(
          "new-window",
          "-a",
          "-t",
          session_target(session),
          "-n",
          name,
          "-c",
          path.to_s,
          command
        )
      end

      # Type `keys` into `pane` followed by Enter.
      def send_keys(pane, keys)
        tmux_exec("send-keys", "-t", pane, keys, "Enter")
      end

      def window_exists?(session, name)
        list_windows(session).include?(name)
      end

      # The current command of a window's first pane, or nil when the window
      # does not exist.
      def pane_command(session, window)
        target = Tmux.window_target(session, window)
        # The escaped \#{...} is a literal tmux format string, not Ruby interpolation.
        result = tmux_output(
          "list-panes",
          "-t",
          target,
          "-F",
          "\#{pane_current_command}"
        )
        return nil unless result&.success?

        result.stdout.lines.first&.chomp
      end

      def select_window(session, name)
        tmux_exec("select-window", "-t", Tmux.window_target(session, name))
      end

      def kill_window(session, name)
        tmux_exec("kill-window", "-t", Tmux.window_target(session, name))
      end

      # Window names in `session`; empty when the session does not exist.
      def list_windows(session)
        result = tmux_output(
          "list-windows",
          "-t",
          session_target(session),
          "-F",
          "\#{window_name}"
        )
        return [] unless result&.success?

        result.stdout.lines.map(&:chomp)
      end

      private

      # A brand-new session whose first window IS the target: create it
      # directly, so the seed window and a separate new-window call don't
      # produce two windows with the same name. Returns the first pane's id.
      def create_first_pane(session, name, path, default_window_name)
        if !session_exists?(session) && default_window_name == name
          result = tmux_run(
            "new-session",
            "-d",
            "-s",
            session,
            "-n",
            name,
            "-P",
            "-F",
            "\#{pane_id}",
            "-c",
            path.to_s
          )
          return result.stdout.strip
        end

        ensure_session(
          session,
          path,
          default_window_name
        )

        result = tmux_run(
          "new-window",
          "-a",
          "-P",
          "-F",
          "\#{pane_id}",
          "-t",
          session_target(session),
          "-n",
          name,
          "-c",
          path.to_s
        )
        result.stdout.strip
      end

      def layout_empty?(layout)
        layout.columns? ? layout.columns.empty? : layout.rows.empty?
      end

      # Walk the plan's splits, issuing each split-window call and collecting
      # the resulting pane ids (index 0 is the window's initial pane).
      def realize_splits(plan, first_pane, path)
        pane_ids = [first_pane]
        plan.splits.each do |split|
          target_id = pane_ids[split.target]
          new_id = split_pane(
            split.direction,
            target_id,
            path,
            split.percentage
          )
          pane_ids << new_id
        end
        pane_ids
      end

      def run_pane_commands(plan, pane_ids, template_vars)
        plan.commands.each do |pane_command|
          pane_id = pane_ids[pane_command.pane]
          command = Layout.substitute_template_vars(pane_command.command, template_vars)
          wait_for_shell(pane_id)
          send_keys(pane_id, command)
        end
      end

      # Split `target` in `direction` (:horizontal -> new pane right,
      # :vertical -> new pane below) giving the new pane `percentage`% of the
      # space; returns its pane id.
      def split_pane(direction, target, path, percentage)
        flag = direction == :horizontal ? "-h" : "-v"
        result = tmux_run(
          "split-window",
          flag,
          "-t",
          target,
          "-c",
          path.to_s,
          "-l",
          "#{percentage}%",
          "-P",
          "-F",
          "\#{pane_id}"
        )
        result.stdout.strip
      end

      # Block until `pane`'s shell can execute commands, bounded at 10 seconds:
      # a detached `run-shell -d 10` signals the same wait channel, so a shell
      # that never comes up cannot deadlock orn.
      def wait_for_shell(pane)
        channel = "orn-ready-#{pane.delete("%")}"
        timeout_armed = arm_shell_wait_timeout(channel)
        tmux_exec("send-keys", "-t", pane, Tmux.shell_ready_command(channel), "Enter")
        tmux_exec("wait-for", channel) if timeout_armed
      end

      # `run-shell -d` needs tmux 3.2+ (Ubuntu 20.04 and Debian 11 ship
      # older). Without the timeout arm a plain wait-for could hang forever,
      # so on older tmux the wait is skipped and pane commands are typed
      # right away.
      def arm_shell_wait_timeout(channel)
        tmux_exec("run-shell", "-b", "-d", "10", "tmux wait-for -S #{channel}")
        true
      rescue Orn::Error
        false
      end

      # Trailing colon forces session interpretation: a bare name is a
      # target-window, which tmux first matches against window names in the
      # caller's current session.
      def session_target(session)
        "#{session}:"
      end

      def safe_realpath(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end

      def tmux_exec(*args)
        @cmd.exec("tmux", *args)
      end

      def tmux_run(*args)
        @cmd.run("tmux", *args)
      end

      def tmux_output(*args)
        @cmd.output("tmux", *args)
      rescue Orn::Error
        nil
      end
    end
  end
end
