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

    # Commands that run without a project, so the startup config-version gate
    # is skipped for them: printing the version, showing help, and listing
    # completion candidates. `complete` also has a faster short-circuit in
    # `exe/orn`; this covers the slower path through the full CLI.
    VERSIONLESS_COMMANDS = %w[version help complete].freeze

    # Flags that ask for the version or help instead of running a command.
    # None of orn's own options use these spellings, so their presence always
    # means "just print version/help", which needs no project.
    VERSIONLESS_FLAGS = %w[--version -V --help -h].freeze

    def initialize(argv)
      @argv = argv
    end

    def run
      return Orn::TUI.launch(global: global_requested?) unless subcommand?

      # A config older than the running orn (pending migration) must be
      # refused before the command touches it. Do this here, once the project
      # is known, so every command is covered in one place rather than each
      # command re-checking.
      enforce_config_versions

      # `Thor.start` is Thor's entry point: it parses the argv it is given
      # (the CLI's own ARGV, minus the root-only flag), selects the matching
      # command, and invokes it.
      Orn::CLI.start(cli_argv)
    end

    private

    # Runs the startup config-version gate for commands that need a project.
    # When the command needs no project, or the current directory is not an
    # orn project, there is nothing to enforce and dispatch proceeds. A config
    # that is behind the binary raises here and stops dispatch.
    def enforce_config_versions
      return if versionless_command?

      project_root = discover_project_root
      return unless project_root

      Orn::Config::Migrate.enforce_project_versions(project_root)
    end

    # The project root, or nil when the current directory is not an orn
    # project. Only discovery failures are swallowed; the command itself
    # re-discovers and reports the same error later if it truly needs a
    # project.
    def discover_project_root
      Orn::Git::Project.discover_root
    rescue Orn::Error
      nil
    end

    # True when the invocation only prints the version or help, or lists
    # completion candidates, none of which read a project config.
    def versionless_command?
      command = cli_argv.first
      VERSIONLESS_COMMANDS.include?(command) || cli_argv.intersect?(VERSIONLESS_FLAGS)
    end

    def subcommand?
      @argv.any? { |arg| !GLOBAL_FLAGS.include?(arg) }
    end

    def global_requested?
      @argv.intersect?(ROOT_ONLY_FLAGS)
    end

    # Normalize the leading run of flags before the subcommand token. Two
    # things happen there:
    #
    # - Root-only flags (`-g`/`--global`) are the meaningless-to-Thor TUI flags
    #   and are dropped.
    # - The remaining global flags (`-v`/`--json`) are relocated to the end of
    #   the argv. Thor treats a leading `-`-prefixed token as "no command
    #   given" and prints help instead of dispatching, so a global flag placed
    #   before the subcommand must move past it. Appending (rather than
    #   inserting right after the subcommand) also clears the same hazard for
    #   subcommand groups, whose nested Thor class would likewise choke on a
    #   flag sitting before its own command (`config --json show`).
    #
    # Once the subcommand token appears, everything after it belongs to that
    # command and is left untouched (e.g. `config migrate --global` is the
    # subcommand's own flag and must reach Thor as written).
    def cli_argv
      subcommand_index = @argv.index { |arg| !GLOBAL_FLAGS.include?(arg) }
      return @argv.reject { |arg| ROOT_ONLY_FLAGS.include?(arg) } if subcommand_index.nil?

      leading_globals = @argv[0...subcommand_index].reject { |arg| ROOT_ONLY_FLAGS.include?(arg) }
      @argv[subcommand_index..] + leading_globals
    end
  end
end
