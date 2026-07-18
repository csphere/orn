# frozen_string_literal: true

module Orn
  module TUI
    # The tmux bootstrap and event loops that host the project and global TUIs.
    #
    # Outside the TUI process (`ORN_TUI` unset) this launches an `orn` tmux
    # window that re-execs the binary; inside it (the re-exec), the event loop
    # runs directly in the terminal. Entirely interactive: validated by running
    # a real terminal, not by unit tests.
    module Bootstrap
      module_function

      # Bare `orn` entry point. Routes to the global TUI when `global` is set or
      # no project is discoverable from the cwd, otherwise to the project TUI.
      def run(global:)
        project = discover_project
        if ENV["ORN_TUI"]
          global || project.nil? ? run_global_direct : run_direct(project)
        elsif global || project.nil?
          bootstrap_global
        else
          bootstrap(project)
        end
      end

      def discover_project
        Orn::Git::Project.discover
      rescue Orn::Error
        nil
      end

      # Run the project TUI event loop in this terminal, recording the project
      # in the MRU state first.
      def run_direct(project)
        mru = State.load
        mru.touch(project.root)
        mru.save
        app = App.for_project(Orn::OutputMode.quiet, project)
        with_terminal { |terminal| run_loop(terminal, app) }
      end

      # Run the global TUI event loop in this terminal, after returning stranded
      # hub panes and clearing stale key bindings.
      def run_global_direct
        output = Orn::OutputMode.quiet
        Hub.reconcile(output)
        Hub.remove_bindings(output)
        app = GlobalApp.build(output, Orn::Config::GlobalTuiConfig.load)
        with_terminal do |terminal|
          run_global_loop(terminal, app)
        ensure
          app.close_all_tabs
        end
      end

      # Launch (or select) the project TUI window in the project's session.
      def bootstrap(project)
        output = Orn::OutputMode.quiet
        session = Orn::Session.session_name(project)
        base = project.config.base
        bootstrap_tui(
          output,
          session,
          project.root,
          default_window_name: base,
          reorder_base: base,
          relaunch_suffix: ""
        )
      end

      # Launch (or select) the global TUI window in the configured session,
      # rooted at the first scan root.
      def bootstrap_global
        output = Orn::OutputMode.quiet
        config = Orn::Config::GlobalTuiConfig.load
        cwd = config.scan_roots.first || Dir.pwd
        bootstrap_tui(
          output,
          config.session,
          cwd,
          default_window_name: nil,
          reorder_base: "",
          relaunch_suffix: " -g"
        )
      end

      # Select or (re-)launch the `orn` TUI window in `session`, at `cwd`.
      # `default_window_name` seeds a brand-new session's first window;
      # `reorder_base` is the base branch reorder keeps pinned second (empty for
      # the global TUI); `relaunch_suffix` is appended to the re-exec command
      # (" -g" for the global TUI).
      def bootstrap_tui(output, session, cwd, default_window_name:, reorder_base:, relaunch_suffix:)
        return if reuse_existing_window(output, session, reorder_base)

        tui_cmd = Orn::TUI.relaunch_command(relaunch_suffix)
        if ENV["TMUX"]
          launch_window(
            output,
            session,
            cwd,
            tui_cmd,
            default_window_name: default_window_name,
            reorder_base: reorder_base
          )
        else
          launch_session(session, cwd, tui_cmd)
        end
      end

      # Select the live `orn` window if one is already running; otherwise kill a
      # stale one. Returns true when an existing live window was selected.
      def reuse_existing_window(output, session, reorder_base)
        return false unless Orn::Tmux.window_exists?(output, session, TUI_WINDOW)

        if Orn::Tmux.pane_command(output, session, TUI_WINDOW) == "orn"
          Orn::TUI.reorder_windows(output, session, reorder_base)
          Orn::Tmux.select_window(output, session, TUI_WINDOW)
          return true
        end

        begin
          Orn::Tmux.kill_window(output, session, TUI_WINDOW)
        rescue Orn::Error
          nil
        end
        false
      end

      # From inside tmux: add the `orn` window to the (ensured) session and
      # select it.
      def launch_window(output, session, cwd, tui_cmd, default_window_name:, reorder_base:)
        Orn::Tmux.ensure_session(output, session, cwd, default_window_name)
        Orn::Cmd.new(output_mode: output).exec(
          "tmux", "new-window", "-a", "-t", "#{session}:", "-n", TUI_WINDOW, "-c", cwd.to_s, tui_cmd
        )
        Orn::TUI.reorder_windows(output, session, reorder_base)
        Orn::Tmux.select_window(output, session, TUI_WINDOW)
      end

      # From outside tmux: create a new session running the TUI and attach to it
      # (blocks until the session exits).
      def launch_session(session, cwd, tui_cmd)
        ok = system("tmux", "new-session", "-s", session, "-n", TUI_WINDOW, "-c", cwd.to_s, tui_cmd)
        raise Orn::Error, "tmux session exited with an error" unless ok
      end

      # Project TUI event loop: draw, dispatch key presses per input mode, tick
      # the spinner, and refresh on cadence.
      def run_loop(terminal, app)
        last_area = nil
        loop do
          last_area = redraw_on_resize(terminal, last_area)
          terminal.draw { |frame| Ui.draw(frame, app) }
          key = terminal.poll(app.poll_timeout)
          return if key && dispatch_project(app, key) == :quit

          app.spinner_tick += 1 if app.any_agent_working?
          app.maybe_refresh
        end
      end

      # Global TUI event loop: draw, dispatch, tick the spinner, poll agent
      # focus, and refresh on cadence.
      def run_global_loop(terminal, app)
        last_area = nil
        loop do
          last_area = redraw_on_resize(terminal, last_area) { app.enforce_layout }
          terminal.draw { |frame| GlobalUi.draw(frame, app) }
          key = terminal.poll(app.poll_timeout)
          return if key && dispatch_global(app, key) == :quit

          app.spinner_tick += 1 if app.any_agent_working?
          app.poll_focus
          app.maybe_refresh
        end
      end

      # React to a terminal resize before the next draw. The size is re-read
      # each tick (rather than trapping SIGWINCH, which cannot wake the poll
      # early without a self-pipe), so a resize is picked up within one poll
      # timeout. On a change, clear the screen so a shrunk terminal keeps no
      # stale rows, and run the optional callback the global TUI uses to
      # re-apply its sidebar split. Returns the current area for the next
      # comparison. The redraw itself happens in the caller's `draw`, which
      # reads the fresh size.
      def redraw_on_resize(terminal, last_area)
        area = terminal.area
        if last_area && area != last_area
          terminal.clear
          yield if block_given?
        end
        area
      end

      # Dispatch a key press for the project TUI, per input mode. Returns :quit
      # when the loop should exit.
      def dispatch_project(app, key)
        app.clear_error
        if app.mode.new_branch?
          dispatch_new_branch(app, key)
        elsif app.mode.confirm_remove?
          char?(key, "y") ? app.confirm_remove : app.cancel_mode
        else
          dispatch_normal(app, key)
        end
      end

      # Normal-mode key tokens mapped to the zero-argument App action they
      # invoke ("q" is handled separately as the quit signal).
      NORMAL_ACTIONS = {
        "r" => :refresh,
        :enter => :open_selected,
        "c" => :close_selected,
        "n" => :start_new_branch,
        "d" => :start_remove,
        "j" => :move_down,
        :down => :move_down,
        "k" => :move_up,
        :up => :move_up
      }.freeze

      # Global-mode key tokens mapped to the zero-argument GlobalApp action they
      # invoke ("q" quits and the cycle keys are handled separately, since they
      # take a direction).
      GLOBAL_ACTIONS = {
        "r" => :full_refresh,
        :enter => :enter_selected,
        " " => :toggle_expanded,
        "x" => :close_tab,
        "j" => :move_down,
        :down => :move_down,
        "k" => :move_up,
        :up => :move_up
      }.freeze

      # The cycle keys ("n"/"p") and the direction each cycles the visible tab.
      CYCLE_KEYS = {
        Hub::CYCLE_NEXT_INPUT => true,
        Hub::CYCLE_PREV_INPUT => false
      }.freeze

      def dispatch_normal(app, key)
        token = key_token(key)
        return :quit if token == "q"

        action = NORMAL_ACTIONS[token]
        app.public_send(action) if action
        nil
      end

      def dispatch_new_branch(app, key)
        case key.code
        when :esc then app.cancel_mode
        when :enter then app.confirm_new_branch
        when :backspace then app.new_branch_pop_char
        when :char then app.new_branch_push_char(key.char)
        end
        nil
      end

      # Dispatch a key press for the global TUI. Returns :quit when the loop
      # should exit.
      def dispatch_global(app, key)
        app.clear_error
        token = key_token(key)
        return :quit if token == "q"

        if CYCLE_KEYS.key?(token)
          app.cycle_tab(CYCLE_KEYS[token])
        else
          action = GLOBAL_ACTIONS[token]
          app.public_send(action) if action
        end
        nil
      end

      # Normalize a key event to a lookup token: the character for a printable
      # key, otherwise the code symbol (:enter, :up, :down, ...).
      def key_token(key)
        key.code == :char ? key.char : key.code
      end

      def char?(key, character)
        key.code == :char && key.char == character
      end

      # Enter raw mode + the alt screen for the duration of the block, restoring
      # the terminal on exit or signal so a crash never leaves it wedged.
      def with_terminal
        backend = TermBackend.new
        install_signal_restore(backend)
        backend.start
        yield Terminal.new(backend)
      ensure
        backend.stop
      end

      def install_signal_restore(backend)
        %w[INT TERM].each do |signal|
          trap(signal) do
            backend.stop
            exit(1)
          end
        end
      end
    end
  end
end
