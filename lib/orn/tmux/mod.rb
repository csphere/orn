# frozen_string_literal: true

module Orn
  # Tmux session, window, and pane orchestration: creating worktree windows
  # from layout plans and wrapping the tmux CLI commands orn relies on. The
  # trust-gated open_window family lives elsewhere (it needs the trust layer).
  module Tmux
    # Create `session` detached and rooted at `path` if it does not already
    # exist; its seed window is named `default_window_name` when given.
    def self.ensure_session(output_mode, session, path, default_window_name = nil)
      return if Session.session_exists?(output_mode, session)

      args = ["new-session", "-d", "-s", session]
      args.push("-n", default_window_name) if default_window_name
      args.push("-c", path.to_s)
      tmux_exec(output_mode, *args)
    end

    # Create window `name` in `session` (creating the session if needed),
    # realize `layout` by splitting panes, then run each configured pane
    # command once its shell is ready. Selects the window when done.
    def self.create_window(output_mode, session, name, path, layout, template_vars: {}, default_window_name: nil)
      warn_if_old_tmux

      first_pane = create_first_pane(
        output_mode,
        session,
        name,
        path,
        default_window_name
      )
      target = window_target(session, name)

      if layout_empty?(layout)
        tmux_exec(output_mode, "select-window", "-t", target)
        return
      end

      plan = layout.columns? ? Layout.plan_columns(layout.columns) : Layout.plan_rows(layout.rows)
      pane_ids = realize_splits(
        output_mode,
        plan,
        first_pane,
        path
      )
      run_pane_commands(
        output_mode,
        plan,
        pane_ids,
        template_vars
      )

      tmux_exec(output_mode, "select-pane", "-t", pane_ids[plan.focus_pane])
      tmux_exec(output_mode, "select-window", "-t", target)
    end

    # Type `keys` into `pane` followed by Enter.
    def self.send_keys(output_mode, pane, keys)
      tmux_exec(output_mode, "send-keys", "-t", pane, keys, "Enter")
    end

    # A tmux target string for `window` inside `session` (`session:window`).
    def self.window_target(session, window)
      "#{session}:#{window}"
    end

    # The command typed into a fresh pane: clear shell startup noise, then
    # signal `channel` so orn knows the shell is accepting input.
    def self.shell_ready_command(channel)
      "clear; tmux clear-history; tmux wait-for -S #{channel}"
    end

    def self.window_exists?(output_mode, session, name)
      list_windows(output_mode, session).include?(name)
    end

    # The current command of a window's first pane, or nil when the window
    # does not exist.
    def self.pane_command(output_mode, session, window)
      target = window_target(session, window)
      # The escaped \#{...} is a literal tmux format string, not Ruby interpolation.
      result = tmux_output(
        output_mode,
        "list-panes",
        "-t",
        target,
        "-F",
        "\#{pane_current_command}"
      )
      return nil unless result&.success?

      result.stdout.lines.first&.chomp
    end

    def self.select_window(output_mode, session, name)
      tmux_exec(output_mode, "select-window", "-t", window_target(session, name))
    end

    def self.kill_window(output_mode, session, name)
      tmux_exec(output_mode, "kill-window", "-t", window_target(session, name))
    end

    # Window names in `session`; empty when the session does not exist.
    def self.list_windows(output_mode, session)
      # Trailing colon forces session interpretation, consistent with the
      # other session-level targets here.
      target = "#{session}:"
      result = tmux_output(
        output_mode,
        "list-windows",
        "-t",
        target,
        "-F",
        "\#{window_name}"
      )
      return [] unless result&.success?

      result.stdout.lines.map(&:chomp)
    end

    # Warn once per process when tmux is older than 2.9, which lacks the
    # percentage form of `split-window -l` used for pane sizing.
    def self.warn_if_old_tmux
      return if @version_checked

      @version_checked = true
      result = Orn::Cmd.new(output_mode: OutputMode.quiet).output("tmux", "-V")
      return unless result.success?

      warn_if_tmux_too_old(result.stdout.strip)
    rescue Orn::Error
      nil
    end

    # A brand-new session whose first window IS the target: create it directly,
    # so the seed window and a separate new-window call don't produce two
    # windows with the same name. Returns the first pane's id.
    def self.create_first_pane(output_mode, session, name, path, default_window_name)
      if !Session.session_exists?(output_mode, session) && default_window_name == name
        result = tmux_run(
          output_mode,
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
        output_mode,
        session,
        path,
        default_window_name
      )

      # Trailing colon forces session interpretation: a bare name is a
      # target-window, which tmux first matches against window names in the
      # caller's current session.
      session_target = "#{session}:"
      result = tmux_run(
        output_mode,
        "new-window",
        "-a",
        "-P",
        "-F",
        "\#{pane_id}",
        "-t",
        session_target,
        "-n",
        name,
        "-c",
        path.to_s
      )
      result.stdout.strip
    end

    def self.layout_empty?(layout)
      layout.columns? ? layout.columns.empty? : layout.rows.empty?
    end

    # Walk the plan's splits, issuing each split-window call and collecting the
    # resulting pane ids (index 0 is the window's initial pane).
    def self.realize_splits(output_mode, plan, first_pane, path)
      pane_ids = [first_pane]
      plan.splits.each do |split|
        target_id = pane_ids[split.target]
        new_id = split_pane(
          output_mode,
          split.direction,
          target_id,
          path,
          split.percentage
        )
        pane_ids << new_id
      end
      pane_ids
    end

    def self.run_pane_commands(output_mode, plan, pane_ids, template_vars)
      plan.commands.each do |pane_command|
        pane_id = pane_ids[pane_command.pane]
        command = Layout.substitute_template_vars(pane_command.command, template_vars)
        wait_for_shell(output_mode, pane_id)
        send_keys(
          output_mode,
          pane_id,
          command
        )
      end
    end

    # Split `target` in `direction` (:horizontal -> new pane right, :vertical ->
    # new pane below) giving the new pane `percentage`% of the space; returns
    # its pane id.
    def self.split_pane(output_mode, direction, target, path, percentage)
      flag = direction == :horizontal ? "-h" : "-v"
      result = tmux_run(
        output_mode,
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
    def self.wait_for_shell(output_mode, pane)
      channel = "orn-ready-#{pane.delete("%")}"
      tmux_exec(output_mode, "run-shell", "-b", "-d", "10", "tmux wait-for -S #{channel}")
      tmux_exec(output_mode, "send-keys", "-t", pane, shell_ready_command(channel), "Enter")
      tmux_exec(output_mode, "wait-for", channel)
    end

    def self.warn_if_tmux_too_old(version_line)
      return unless version_line.start_with?("tmux ")

      ver = version_line.delete_prefix("tmux ")
      parts = ver.split(".")
      major = Integer(parts[0].to_s, exception: false)
      minor = Integer(parts[1].to_s[/\A\d+/].to_s, exception: false)
      return if major.nil? || minor.nil?
      return unless major < 2 || (major == 2 && minor < 9)

      warn "Warning: tmux 2.9+ required (found #{ver}). Split pane sizing may not work correctly."
    end

    def self.tmux_exec(output_mode, *args)
      Orn::Cmd.new(output_mode: output_mode).exec("tmux", *args)
    end

    def self.tmux_run(output_mode, *args)
      Orn::Cmd.new(output_mode: output_mode).run("tmux", *args)
    end

    def self.tmux_output(output_mode, *args)
      Orn::Cmd.new(output_mode: output_mode).output("tmux", *args)
    rescue Orn::Error
      nil
    end

    private_class_method :create_first_pane,
      :layout_empty?,
      :realize_splits,
      :run_pane_commands,
      :split_pane,
      :wait_for_shell,
      :warn_if_tmux_too_old,
      :tmux_exec,
      :tmux_run,
      :tmux_output
  end
end
