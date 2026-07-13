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
          Show.new(output_mode: Orn::OutputMode.from_options(options)).run
        end

        desc "migrate", "Upgrade config files to the current schema version"
        method_option :dry_run,
          type: :boolean,
          desc: "Preview changes without writing"
        method_option :yes,
          type: :boolean,
          desc: "Non-interactive: keep customized values, accept new defaults"
        method_option :global,
          type: :boolean,
          desc: "Migrate only the global config (~/.config/orn/default.yaml)"
        method_option :project,
          type: :boolean,
          desc: "Migrate only the project config (.orn/config.yaml)"
        def migrate
          # Thor has no conflicts_with, so enforce the mutual exclusion by hand.
          raise Orn::Error, "--global and --project cannot be used together" if options[:global] && options[:project]

          Migrate.new(
            output_mode: Orn::OutputMode.from_options(options),
            dry_run: options[:dry_run] || false,
            global_only: options[:global] || false,
            project_only: options[:project] || false
          ).run
        end
      end
    end
  end
end
