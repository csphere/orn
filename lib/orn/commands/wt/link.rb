# frozen_string_literal: true

module Orn
  module Commands
    module Wt
      # `orn wt link`: apply the configured symlinks to the current worktree,
      # for worktrees created before the symlink config was added or changed.
      class Link
        Result = Data.define(
          :worktree_path,
          :created,
          :skipped
        ) do
          def to_json_hash
            {
              "worktree_path" => worktree_path,
              "created" => created,
              "skipped" => skipped
            }
          end
        end

        def initialize(output_mode:)
          @output_mode = output_mode
        end

        def run
          result = run_inner
          @output_mode.json ? Commands::Output.print_json(result.to_json_hash) : print_result(result)
        end

        # Creates the configured symlinks in the current directory, assumed to be
        # a worktree of the project.
        def run_inner
          project = Orn::Git::Project.discover
          wt_path = Dir.pwd
          created, skipped = Orn::Symlink.create_symlinks(
            project.root,
            wt_path,
            project.config.base,
            project.config.symlinks
          )
          Result.new(
            worktree_path: wt_path,
            created: created,
            skipped: skipped
          )
        end

        private

        def print_result(result)
          if result.created.empty? && result.skipped.empty?
            puts "No symlinks to create"
            return
          end

          result.created.each { |path| puts "  created: #{path}" }
          result.skipped.each { |path| puts "  skipped: #{path}" }
        end
      end
    end
  end
end
