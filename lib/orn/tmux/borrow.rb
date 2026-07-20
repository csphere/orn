# frozen_string_literal: true

module Orn
  module Tmux
    # Pane user option names used to tag borrowed panes. Stored in the tmux
    # server so bookkeeping survives an orn crash. Namespaced to orn; nothing
    # else reads them.
    OPT_HOME_SESSION = "@orn_home_session"
    OPT_HOME_WINDOW = "@orn_home_window"

    # A pane currently borrowed into a hub window, identified by its tags.
    BorrowedPane = Data.define(
      :pane_id,
      :home_session,
      :home_window
    )

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

    # A tmux format condition that is truthy only for `window` in `session`.
    # Used to scope root-table key bindings to the hub window.
    def self.window_guard_condition(session, window)
      "\#{&&:\#{==:\#{session_name},#{session}},\#{==:\#{window_name},#{window}}}"
    end
  end
end
