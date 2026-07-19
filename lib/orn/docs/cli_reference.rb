# frozen_string_literal: true

module Orn
  module Docs
    # Generates docs/cli.md from the Thor command registry, so the checked-in
    # reference cannot drift from the CLI itself. `rake docs` writes the file;
    # CI regenerates it and fails on any diff.
    #
    # The TUI launch flags (`-g`/`--global`, and bare `orn` itself) live in
    # the pre-Thor shim, so the header documents them by hand.
    module CliReference
      HEADER = <<~MD
        # orn CLI reference

        Generated from the CLI definitions by `just docs`. Do not edit by
        hand; CI fails when this file is out of date.

        ## Launching the TUIs

        `orn` with no subcommand opens a TUI instead of running a command:

        - `orn`: the project TUI inside a project, the global hub elsewhere
        - `orn -g` / `orn --global`: the global hub from anywhere

        The `-g`/`--global` flag only exists on the bare invocation; it is
        not an option of any command below.

        ## Global options

        Every command accepts:
      MD

      def self.generate
        sections = [
          HEADER.chomp,
          options_table(Orn::CLI.class_options.values),
          "## Commands"
        ]
        subcommand_classes = Orn::CLI.subcommand_classes
        plain, groups = Orn::CLI.commands
          .reject { |name, command| skip?(name, command) }
          .partition { |name, _command| !subcommand_classes.key?(name) }

        # Plain commands first: a group's `##` heading would otherwise swallow
        # any later `###` command into its section.
        plain.map(&:last).each { |command| sections << command_section(command) }
        groups.each do |name, command|
          sections.concat(group_sections(name, command, subcommand_classes[name]))
        end
        "#{sections.join("\n\n")}\n"
      end

      # `help` is Thor's own and self-evident; hidden commands are internal
      # or deprecated.
      def self.skip?(name, command)
        name == "help" || command.hidden?
      end

      # A subcommand group: one heading with the group's summary, then a
      # section per nested command.
      def self.group_sections(group_name, group_command, group_class)
        sections = ["## `orn #{group_name}`\n\n#{group_command.description}"]
        group_class.commands.each do |name, command|
          next if skip?(name, command)

          sections << command_section(
            command,
            prefix: "orn #{group_name}",
            level: "###"
          )
        end
        sections
      end

      def self.command_section(command, prefix: "orn", level: "###")
        section = "#{level} `#{prefix} #{command.usage}`\n\n#{command.description}"
        long_description = command.long_description
        section << "\n\n#{long_description}" if long_description
        method_options = command.options.values
        section << "\n\n#{options_table(method_options)}" unless method_options.empty?
        section
      end

      def self.options_table(options)
        rows = options.map do |option|
          "| `#{signature(option)}` | #{annotated_description(option)} |"
        end
        [
          "| Option | Description |",
          "| --- | --- |",
          *rows
        ].join("\n")
      end

      # `-v, --verbose` for booleans, `--base BASE` for value options.
      def self.signature(option)
        spellings = [*option.aliases, "--#{option.name.tr("_", "-")}"].join(", ")
        return spellings if option.type == :boolean

        "#{spellings} #{option.banner}"
      end

      # The option description, with required/default appended so the table
      # carries everything `orn help <command>` shows.
      def self.annotated_description(option)
        notes = []
        notes << "required" if option.required
        notes << "default: `#{option.default}`" unless option.default.nil? || option.default == false
        return option.description.to_s if notes.empty?

        "#{option.description} (#{notes.join(", ")})"
      end
    end
  end
end
