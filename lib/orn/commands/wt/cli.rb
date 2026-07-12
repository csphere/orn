# frozen_string_literal: true

require "thor"

module Orn
  module Commands
    module Wt
      # Thor subcommand group for `orn wt` (worktree-only commands). Registered
      # on the root CLI via `subcommand`. Only `list` is wired so far.
      class CLI < Thor
        def self.exit_on_failure?
          true
        end

        # Re-declared because Thor does not propagate the root class options
        # into a subcommand group.
        class_option :verbose,
          type: :boolean,
          aliases: "-v",
          desc: "Log executed commands to stderr"
        class_option :json,
          type: :boolean,
          desc: "Emit machine-readable JSON output"

        desc "list", "List the project's worktrees"
        def list
          List.new(output_mode: Orn::OutputMode.from_options(options)).run
        end

        desc "remove BRANCH [BRANCH ...]", "Remove worktrees (with --prune, also their branches)"
        option :prune, type: :boolean, default: false, desc: "Also delete the local and remote branches"
        option :force, type: :boolean, default: false, desc: "Skip the confirmation prompt"
        def remove(*branches)
          raise Orn::Error, "wt remove requires at least one branch" if branches.empty?

          Remove.new(output_mode: Orn::OutputMode.from_options(options))
            .run(branches, prune: options[:prune], force: options[:force])
        end

        desc "link", "Apply the configured symlinks to the current worktree"
        def link
          Link.new(output_mode: Orn::OutputMode.from_options(options)).run
        end
      end
    end
  end
end
