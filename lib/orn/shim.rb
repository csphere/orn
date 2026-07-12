# frozen_string_literal: true

module Orn
  # Pre-dispatch entry point. Thor cannot cleanly express a default command
  # that also reads a root-only flag, so the shim owns that one decision:
  # with no subcommand it launches the TUI (global when `-g`/`--global` is
  # present); otherwise it hands off to the Thor CLI.
  class Shim
    # Flags that may appear before a subcommand without themselves being a
    # subcommand. `-v`/`--json` are true global options that Thor also parses;
    # `-g`/`--global` is a root-only flag meaningful only to the TUI route.
    GLOBAL_FLAGS = %w[-v --verbose --json -g --global].freeze
    ROOT_ONLY_FLAGS = %w[-g --global].freeze

    def initialize(argv)
      @argv = argv
    end

    def run
      # `Thor.start` is Thor's entry point: it parses the argv it is given
      # (the CLI's own ARGV, minus the root-only flag), selects the matching
      # command, and invokes it.
      return Orn::CLI.start(cli_argv) if subcommand?

      Orn::TUI.launch(global: global_requested?)
    end

    private

    def subcommand?
      @argv.any? { |arg| !GLOBAL_FLAGS.include?(arg) }
    end

    def global_requested?
      @argv.intersect?(ROOT_ONLY_FLAGS)
    end

    # The root-only flag is meaningless once a subcommand is present (Thor
    # does not know it), so strip it before dispatching.
    def cli_argv
      @argv.reject { |arg| ROOT_ONLY_FLAGS.include?(arg) }
    end
  end
end
