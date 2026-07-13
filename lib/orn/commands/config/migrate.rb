# frozen_string_literal: true

module Orn
  module Commands
    module Config
      # Handles `orn config migrate` for the project config, the global config,
      # or both (the default). Missing files are reported and skipped. It
      # discovers only the project root (not the full config), so it works even
      # when the config is outdated.
      class Migrate
        def initialize(output_mode:, dry_run:, global_only:, project_only:)
          @output_mode = output_mode
          @dry_run = dry_run
          @global_only = global_only
          @project_only = project_only
        end

        def run
          project_root = Orn::Git::Project.discover_root
          results = migrate_targets(project_root)
          Orn::Commands::Output.print_json({ files: results.map(&:to_h) }) if @output_mode.json
          nil
        end

        # The [label, path] pairs to migrate, honoring --global / --project.
        def targets(project_root)
          project = ["project", File.join(project_root, ".orn/config.yaml")]
          global_dir = Orn::Config.global_config_dir
          global = global_dir ? ["global", File.join(global_dir, "default.yaml")] : nil

          return [global].compact if @global_only
          return [project] if @project_only

          [project, global].compact
        end

        private

        def migrate_targets(project_root)
          targets(project_root).filter_map do |label, path|
            unless File.exist?(path)
              @output_mode.status("#{label} config not found: #{path}")
              next
            end

            result = Orn::Config::Migrate.migrate_file(path, dry_run: @dry_run)
            print_result(label, result) unless @output_mode.json
            result
          end
        end

        def print_result(label, result)
          return warn "#{label} config is up to date (#{result.to_version}): #{result.path}" if result.up_to_date

          from = result.from_version || "(no version)"
          warn "Migrating #{label} config (#{from} -> #{result.to_version}):"
          result.changes.each { |change| warn "  - #{change}" }
          print_write_summary(result)
        end

        def print_write_summary(result)
          if @dry_run
            warn "(dry run: no changes written)\n"
          elsif result.backup_path
            warn "  backup:  #{result.backup_path}"
            warn "  updated: #{result.path}\n"
          end
        end
      end
    end
  end
end
