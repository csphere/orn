# frozen_string_literal: true

require_relative "tui/geometry"
require_relative "tui/style"
require_relative "tui/buffer"
require_relative "tui/widgets"
require_relative "tui/frame"
require_relative "tui/terminal"

module Orn
  # Terminal UIs for orn: the per-project worktree list and the global
  # multi-repo hub, plus the tmux bootstrap that hosts them in an `orn` window.
  #
  # The immediate-mode rendering substrate (geometry, style, buffer, widgets,
  # frame, terminal) lives in the files required above; the project and global
  # apps and the tmux bootstrap build on it.
  module TUI
    # Event poll timeout while no agent is working, in seconds.
    POLL_TIMEOUT = 0.25
    # Event poll timeout while an agent is working, so the spinner animates.
    FAST_POLL_TIMEOUT = 0.05
    # Cadence of the project TUI's full worktree refresh, in seconds.
    REFRESH_INTERVAL = 3
    # Name of the tmux window hosting a TUI.
    TUI_WINDOW = "orn"
    # Braille frames for the working-agent spinner.
    SPINNER_FRAMES = [
      "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283c}",
      "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280f}"
    ].freeze

    # Symbol, colour, and label for an agent's status indicator, shared by the
    # project and global list renderers. `state` is a detection symbol
    # (`:blocked`/`:working`/`:idle`/`:unknown`).
    def self.agent_indicator(state, spinner_tick)
      case state
      when :blocked then ["\u{25cf}", Color::RED, "blocked"]
      when :working
        frame = SPINNER_FRAMES[spinner_tick % SPINNER_FRAMES.length]
        [frame, Color::YELLOW, "working"]
      when :idle then ["\u{25cb}", Color::GREEN, "idle"]
      else ["\u{00b7}", Color::DARK_GRAY, "idle"]
      end
    end

    # Enforce window order in `session`: [orn, base, sorted worktrees]. Uses
    # swap-window so it works regardless of the base-index setting. `base_branch`
    # is empty for the global TUI, which pins no base.
    def self.reorder_windows(output_mode, session, base_branch)
      cmd = Orn::Cmd.new(output_mode: output_mode)
      result = cmd.output("tmux", "list-windows", "-t", "#{session}:", "-F", "\#{window_name}")
      return unless result.success?

      windows = result.stdout.lines.map(&:chomp)
      return if windows.length <= 1

      apply_window_order(
        cmd,
        session,
        windows,
        desired_order(windows, base_branch)
      )
    end

    # The target window order: the TUI window first, then the base branch, then
    # the remaining worktree windows alphabetically.
    def self.desired_order(windows, base_branch)
      desired = []
      desired << TUI_WINDOW if windows.include?(TUI_WINDOW)
      desired << base_branch if windows.include?(base_branch)
      rest = windows.reject { |name| name == TUI_WINDOW || name == base_branch }.sort
      desired.concat(rest)
    end

    # Swap windows into `desired` order one mismatch at a time, tracking the
    # live positions as each swap lands.
    def self.apply_window_order(cmd, session, windows, desired)
      desired.each_index do |i|
        next if windows[i] == desired[i]

        j = windows.index(desired[i])
        next unless j

        cmd.output("tmux", "swap-window", "-d", "-s", "#{session}:#{windows[i]}", "-t", "#{session}:#{windows[j]}")
        windows[i], windows[j] = windows[j], windows[i]
      end
    end

    # The shell command a tmux window runs to re-exec orn as a TUI process,
    # guarded by the `ORN_TUI` env var so the re-exec runs the event loop
    # directly instead of bootstrapping another window. `suffix` appends flags
    # (" -g" for the global TUI).
    def self.relaunch_command(suffix = "")
      "ORN_TUI=1 exec #{orn_executable}#{suffix}"
    end

    # Absolute path to the running orn executable, for the re-exec command.
    def self.orn_executable
      File.expand_path($PROGRAM_NAME)
    end

    # Bare `orn` entry point: bootstrap the tmux-hosted TUI window, or (inside
    # the re-exec) run the event loop. See Orn::TUI::Bootstrap.
    def self.launch(global:)
      Bootstrap.run(global: global)
    end
  end
end
