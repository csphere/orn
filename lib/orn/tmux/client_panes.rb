# frozen_string_literal: true

module Orn
  module Tmux
    # Pane metadata and capture verbs.
    class Client
      # Metadata for every pane in every window of `session`; empty when the
      # session does not exist or the listing fails.
      def list_panes_metadata(session)
        # Trailing colon forces session interpretation: `-t` is a
        # target-window even with `-s`, so a bare name first matches window
        # names in the caller's current session and `-s` then widens to the
        # wrong session.
        result = tmux_output(
          "list-panes",
          "-s",
          "-t",
          session_target(session),
          "-F",
          PANE_FORMAT
        )
        return [] unless result&.success?

        Tmux.parse_pane_lines(result.stdout, with_session: false)
      end

      # All panes on the server. nil means the listing itself failed: callers
      # must treat that as "no information", not "no panes", since pruning
      # state against a failed listing would drop live panes.
      def list_all_panes_metadata
        result = tmux_output(
          "list-panes",
          "-a",
          "-F",
          PANE_FORMAT_ALL
        )
        return nil unless result&.success?

        Tmux.parse_pane_lines(result.stdout, with_session: true)
      end

      # The visible contents of a pane as plain text; nil when the capture
      # fails.
      def capture_pane(pane_id)
        result = tmux_output(
          "capture-pane",
          "-p",
          "-t",
          pane_id
        )
        return nil unless result&.success?

        result.stdout
      end
    end
  end
end
