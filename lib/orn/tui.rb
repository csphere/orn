# frozen_string_literal: true

module Orn
  # Placeholder for the terminal UI (arriving in phase 11). It exists now so
  # the entry shim has a real dispatch target for the bare `orn` / `orn -g`
  # no-subcommand case.
  module TUI
    def self.launch(global:)
      surface = global ? "global" : "project"
      warn "orn: the #{surface} TUI is not implemented yet (arriving in phase 11)."
    end
  end
end
