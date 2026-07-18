# frozen_string_literal: true

require "yaml"
require "fileutils"

module Orn
  class Config
    # Config schema migration and version enforcement. Structural changes are
    # registered as versioned steps; `orn config migrate` applies them, and
    # command startup refuses to run against configs that still need them.
    #
    # Versioned config migrations gated on the `orn_version` field, using
    # Gem::Version for semver comparisons.
    module Migrate # rubocop:disable Metrics/ModuleLength
      # One structural edit: move a top-level key into a section.
      MoveTopLevel = Data.define(:key, :to_section) do
        def describe(table)
          "move `#{key}` to [#{to_section}]" if table.key?(key)
        end

        # Existing destination keys win: a moved value never overwrites one.
        def apply(table)
          return unless table.key?(key)

          value = table.delete(key)
          section = (table[to_section] ||= {})
          section[key] = value if section.is_a?(Hash) && !section.key?(key)
        end
      end

      # One structural edit: rename a key within a section.
      RenameInSection = Data.define(:section, :old_key, :new_key) do
        def describe(table)
          nested = table[section]
          return unless nested.is_a?(Hash) && nested.key?(old_key)

          "rename `#{section}.#{old_key}` to `#{section}.#{new_key}`"
        end

        def apply(table)
          nested = table[section]
          return unless nested.is_a?(Hash) && nested.key?(old_key)

          value = nested.delete(old_key)
          nested[new_key] = value unless nested.key?(new_key)
        end
      end

      # The changes required to bring a config up to version `to`.
      MigrationStep = Data.define(:to, :changes)

      # What a migration would do: the target version and human-readable
      # descriptions of each change.
      MigrationPlan = Data.define(:to_version, :descriptions)

      # How a config's orn_version compares to the binary version.
      VersionCheck = Data.define(:kind, :config, :binary)

      # Outcome of migrate_file, serialized for `orn config migrate` output.
      MigrateFileResult = Data.define(
        :path, :from_version, :to_version, :changes, :backup_path, :up_to_date
      )

      # Registry of all migration steps, ordered by target version. A single
      # step at the 0.1.0 baseline normalizes a legacy flat config (top-level
      # keys, symlinks.worktree) into the sectioned schema. Future schema changes register newer steps here.
      MIGRATION_STEPS = [
        MigrationStep.new(
          to: Gem::Version.new("0.1.0"),
          changes: [
            MoveTopLevel.new(
              key: "base",
              to_section: "git"
            ),
            MoveTopLevel.new(
              key: "session",
              to_section: "tmux"
            ),
            MoveTopLevel.new(
              key: "columns",
              to_section: "tmux"
            ),
            MoveTopLevel.new(
              key: "rows",
              to_section: "tmux"
            ),
            RenameInSection.new(
              section: "symlinks",
              old_key: "worktree",
              new_key: "base"
            )
          ]
        )
      ].freeze

      # The orn version compiled into the gem.
      def self.binary_version
        Gem::Version.new(Orn::VERSION)
      end

      # How `config_version` compares to `binary`. Absent or unparsable versions
      # both count as :missing.
      def self.check_version(config_version, binary)
        config = parse_version(config_version)
        if config.nil?
          return VersionCheck.new(
            kind: :missing,
            config: nil,
            binary: binary
          )
        end

        kind = if config == binary
                 :match
               else
                 config < binary ? :behind : :ahead
               end
        VersionCheck.new(
          kind: kind,
          config: config,
          binary: binary
        )
      end

      # :behind is a hard error pointing at `orn config migrate`; :ahead and
      # :missing only warn.
      def self.enforce_version(config_version, path, binary)
        check = check_version(config_version, binary)
        case check.kind
        when :match
          nil
        when :behind
          raise Orn::Error,
            "#{path}: config version (#{check.config}) is behind orn (#{binary})\n  " \
            "Run `orn config migrate` to update"
        when :ahead
          warn "warning: #{path}: config version (#{check.config}) is ahead of orn (#{binary})"
        when :missing
          warn "warning: #{path}: no orn_version field; run `orn config migrate` to add it"
        end
      end

      # Startup gate: checks the project and global configs, erroring if either
      # needs migration.
      def self.enforce_project_versions(project_root)
        binary = binary_version
        enforce_file_version(File.join(project_root, ".orn/config.yaml"), binary)
        global_dir = Orn::Config.global_config_dir
        enforce_file_version(File.join(global_dir, "default.yaml"), binary) if global_dir
        nil
      end

      # Errors when the file has pending structural migrations or its version is
      # behind the binary. Missing or unparsable files pass; config loading
      # handles those with its own warnings.
      def self.enforce_file_version(path, binary)
        table = load_table(File.read(path))
        return unless table

        version = string_version(table)
        structural = plan(table, version).descriptions.reject { |change| change.start_with?("set orn_version") }
        unless structural.empty?
          changes = structural.map { |change| "  #{change}" }.join("\n")
          raise Orn::Error, "#{path}: config needs migration\n#{changes}\n\nRun `orn config migrate` to update"
        end

        enforce_version(version, path, binary)
      rescue Errno::ENOENT
        nil
      end

      # Describes pending changes without mutating the table. Always includes a
      # `set orn_version` entry unless the config already matches the binary.
      def self.plan(table, from_version)
        binary = binary_version
        from = parse_version(from_version)
        if from == binary
          return MigrationPlan.new(
            to_version: binary,
            descriptions: []
          )
        end

        descriptions = []
        applicable_steps(from, binary).each do |step|
          step.changes.each do |change|
            description = change.describe(table)
            descriptions << description if description
          end
        end
        descriptions << %(set orn_version = "#{binary}")
        MigrationPlan.new(
          to_version: binary,
          descriptions: descriptions
        )
      end

      # Applies pending steps to the table and stamps orn_version. Existing
      # destination keys win: a moved or renamed value never overwrites one.
      def self.apply(table, from_version)
        binary = binary_version
        from = parse_version(from_version)
        return if from == binary

        applicable_steps(from, binary).each do |step|
          step.changes.each { |change| change.apply(table) }
        end
        table["orn_version"] = binary.to_s
      end

      # First unused `<file>.bak.N` sibling path, counting up from 1.
      def self.next_backup_path(path)
        counter = 1
        counter += 1 while File.exist?("#{path}.bak.#{counter}")
        "#{path}.bak.#{counter}"
      end

      def self.backup(path)
        backup_path = next_backup_path(path)
        FileUtils.cp(path, backup_path)
        backup_path
      rescue SystemCallError => e
        raise Orn::Error, "failed to back up #{path}: #{e.message}"
      end

      # Plans and, unless `dry_run`, applies migration to one config file,
      # backing it up first. Version-only updates edit the text in place and
      # keep comments; structural changes re-serialize the YAML and drop them.
      def self.migrate_file(path, dry_run:)
        contents = File.read(path)
        table = load_table(contents)
        raise Orn::Error, "failed to parse #{path}" unless table

        version = string_version(table)
        migration_plan = plan(table, version)

        return up_to_date_result(path, version, migration_plan) if migration_plan.descriptions.empty?
        return dry_run_result(path, version, migration_plan) if dry_run

        backup_path = backup(path)
        write_migration(path, contents, table, version, migration_plan)
        migrated_result(path, version, migration_plan, backup_path)
      rescue Errno::ENOENT
        raise Orn::Error, "failed to read #{path}"
      end

      # Replaces the orn_version line when it is the first non-comment line,
      # otherwise prepends one; the rest of the file is untouched.
      def self.add_version_line(contents, version)
        new_line = %(orn_version: "#{version}")
        contents.each_line do |line|
          trimmed = line.strip
          next if trimmed.empty? || trimmed.start_with?("#")
          return contents.sub(line, "#{new_line}\n") if trimmed.start_with?("orn_version")

          break
        end
        "#{new_line}\n\n#{contents}"
      end

      # Migration steps that still need to run: those newer than `from` and no
      # newer than `binary`.
      def self.applicable_steps(from, binary)
        MIGRATION_STEPS.select { |step| (from.nil? || step.to > from) && step.to <= binary }
      end

      def self.parse_version(value)
        return nil if value.nil?

        Gem::Version.new(value.to_s)
      rescue ArgumentError
        nil
      end

      # Parses YAML into a hash, or nil for unparsable, empty, or non-mapping
      # content (all of which the caller treats as "nothing to migrate").
      def self.load_table(contents)
        table = YAML.safe_load(contents)
        table.is_a?(Hash) ? table : nil
      rescue Psych::SyntaxError
        nil
      end

      def self.string_version(table)
        table["orn_version"]&.to_s
      end

      def self.serialize(table)
        YAML.dump(table).sub(/\A---\s*\n/, "")
      end

      def self.write_migration(path, contents, table, version, migration_plan)
        if migration_plan.descriptions.any? { |change| !change.start_with?("set orn_version") }
          apply(table, version)
          File.write(path, serialize(table))
        else
          File.write(path, add_version_line(contents, binary_version))
        end
      end

      def self.up_to_date_result(path, version, migration_plan)
        MigrateFileResult.new(
          path: path,

          from_version: version,

          to_version: migration_plan.to_version.to_s,
          changes: [],

          backup_path: nil,

          up_to_date: true
        )
      end

      def self.dry_run_result(path, version, migration_plan)
        MigrateFileResult.new(
          path: path,

          from_version: version,

          to_version: migration_plan.to_version.to_s,
          changes: migration_plan.descriptions,

          backup_path: nil,

          up_to_date: false
        )
      end

      def self.migrated_result(path, version, migration_plan, backup_path)
        MigrateFileResult.new(
          path: path,

          from_version: version,

          to_version: migration_plan.to_version.to_s,
          changes: migration_plan.descriptions,

          backup_path: backup_path,

          up_to_date: false
        )
      end

      private_class_method :applicable_steps,
        :parse_version,
        :load_table,
        :string_version,
        :serialize,
        :write_migration,
        :up_to_date_result,
        :dry_run_result,
        :migrated_result
    end
  end
end
