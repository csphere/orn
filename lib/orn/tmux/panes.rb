# frozen_string_literal: true

module Orn
  module Tmux
    # Identity and display fields of one pane as reported by `list-panes`.
    # `session_name` is populated only by the all-sessions listing (nil
    # otherwise).
    PaneMetadata = Data.define(
      :session_name,
      :window_name,
      :pane_pid,
      :pane_title,
      :pane_current_command,
      :pane_id
    )

    # tmux -F templates. The escaped \#{...} are literal tmux format tokens
    # (not Ruby interpolation); fields are tab-separated.
    PANE_FORMAT = "\#{window_name}\t\#{pane_pid}\t\#{pane_current_command}\t\#{pane_id}\t\#{pane_title}"
    PANE_FORMAT_ALL = "\#{session_name}\t#{PANE_FORMAT}".freeze

    # Metadata for every pane in every window of `session`; empty when the
    # session does not exist or the listing fails.
    def self.list_panes_metadata(output_mode, session)
      # Trailing colon forces session interpretation: `-t` is a target-window
      # even with `-s`, so a bare name first matches window names in the
      # caller's current session and `-s` then widens to the wrong session.
      target = "#{session}:"
      result = tmux_output(output_mode, "list-panes", "-s", "-t", target, "-F", PANE_FORMAT)
      return [] unless result&.success?

      parse_pane_lines(result.stdout, with_session: false)
    end

    # All panes on the server. nil means the listing itself failed: callers
    # must treat that as "no information", not "no panes", since pruning state
    # against a failed listing would drop live panes.
    def self.list_all_panes_metadata(output_mode)
      result = tmux_output(output_mode, "list-panes", "-a", "-F", PANE_FORMAT_ALL)
      return nil unless result&.success?

      parse_pane_lines(result.stdout, with_session: true)
    end

    # The visible contents of a pane as plain text; nil when the capture fails.
    def self.capture_pane(output_mode, pane_id)
      result = tmux_output(output_mode, "capture-pane", "-p", "-t", pane_id)
      return nil unless result&.success?

      result.stdout
    end

    # Parse `list-panes` output into PaneMetadata, dropping malformed lines.
    def self.parse_pane_lines(output, with_session:)
      output.lines.filter_map { |line| parse_pane_line(line.chomp, with_session: with_session) }
    end

    # The title comes last and absorbs any embedded tabs (the split limit): it
    # is free text set by the program running in the pane, and a strict split
    # would silently drop the pane, making it look dead for one refresh.
    def self.parse_pane_line(line, with_session:)
      expected = with_session ? 6 : 5
      fields = line.split("\t", expected)
      return nil unless fields.length == expected

      offset = with_session ? 1 : 0
      pid_field = fields[offset + 1]
      return nil unless pid_field.match?(/\A\d+\z/)

      PaneMetadata.new(
        session_name: with_session ? fields[0] : nil,
        window_name: fields[offset],
        pane_pid: pid_field.to_i,
        pane_title: fields[offset + 4],
        pane_current_command: fields[offset + 2],
        pane_id: fields[offset + 3]
      )
    end

    private_class_method :parse_pane_line
  end
end
