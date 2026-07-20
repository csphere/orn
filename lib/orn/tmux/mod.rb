# frozen_string_literal: true

module Orn
  # Tmux session, window, and pane orchestration. The verbs live on
  # Orn::Tmux::Client; this module holds the pure helpers, constants, and Data
  # types shared with it.
  module Tmux
    # A tmux target string for `window` inside `session` (`session:window`).
    def self.window_target(session, window)
      "#{session}:#{window}"
    end

    # The command typed into a fresh pane: clear shell startup noise, then
    # signal `channel` so orn knows the shell is accepting input.
    def self.shell_ready_command(channel)
      "clear; tmux clear-history; tmux wait-for -S #{channel}"
    end

    # Warn once per process when tmux is older than 3.2, which lacks
    # `run-shell -d` (used to bound the shell-ready wait); 2.9 additionally
    # lacks the percentage form of `split-window -l` used for pane sizing.
    # Stays module-level because the guard is per-process while clients are
    # constructed freely.
    def self.warn_if_old_tmux
      return if @version_checked

      @version_checked = true
      result = Orn::Cmd.new(output_mode: OutputMode.quiet).output("tmux", "-V")
      return unless result.success?

      warn_if_tmux_too_old(result.stdout.strip)
    rescue Orn::Error
      nil
    end

    def self.warn_if_tmux_too_old(version_line)
      return unless version_line.start_with?("tmux ")

      ver = version_line.delete_prefix("tmux ")
      parts = ver.split(".")
      major = Integer(parts[0].to_s, exception: false)
      minor = Integer(parts[1].to_s[/\A\d+/].to_s, exception: false)
      return if major.nil? || minor.nil?
      return unless major < 3 || (major == 3 && minor < 2)

      warn "Warning: tmux 3.2+ required (found #{ver}). Pane sizing and setup may not work correctly."
    end

    private_class_method :warn_if_tmux_too_old
  end
end
