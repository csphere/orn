# frozen_string_literal: true

require "thor"

module Orn
  module Commands
    module Config
      # Thor subcommand group for `orn config`. Registered on the root CLI via
      # `subcommand "config", ...`. `migrate` arrives with the migration layer.
      class CLI < Thor
        def self.exit_on_failure?
          true
        end

        # Global options are re-declared here: Thor does not propagate the root
        # class options to a subcommand group, so `orn config show --json` needs
        # its own `--json` to parse.
        class_option :verbose,
          type: :boolean,
          aliases: "-v",
          desc: "Log executed commands to stderr"
        class_option :json,
          type: :boolean,
          desc: "Emit machine-readable JSON output"

        desc "show", "Print the effective configuration with per-value sources"
        def show
          Show.new(output_mode: output_mode).run
        end

        no_commands do
          def output_mode
            Orn::OutputMode.new(verbose: options[:verbose] || false, json: options[:json] || false)
          end
        end
      end
    end
  end
end
