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
    # Render the app's error line in red; shared by both TUIs' renderers.
    def self.render_error(frame, app, chunk)
      frame.render_widget(Paragraph.line(Line.styled(" #{app.error}", Style.default.fg(Color::RED))), chunk)
    end
    # Braille frames for the working-agent spinner.
    SPINNER_FRAMES = [
      "\u{280b}",
      "\u{2819}",
      "\u{2839}",
      "\u{2838}",
      "\u{283c}",
      "\u{2834}",
      "\u{2826}",
      "\u{2827}",
      "\u{2807}",
      "\u{280f}"
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
