# frozen_string_literal: true

module Orn
  module Commands
    # Thor does not propagate root class options into a subcommand group, so
    # every group re-declares the global flags. Declaring them through this
    # one helper keeps the groups in lockstep.
    module GlobalOptions
      def self.declare(cli_class)
        cli_class.class_option :verbose,
          type: :boolean,
          aliases: "-v",
          desc: "Log executed commands to stderr"
        cli_class.class_option :json,
          type: :boolean,
          desc: "Emit machine-readable JSON output"
        nil
      end
    end
  end
end
