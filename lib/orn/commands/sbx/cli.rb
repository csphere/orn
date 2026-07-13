# frozen_string_literal: true

require "thor"

module Orn
  module Commands
    module Sbx
      # Thor subcommand group for `orn sbx` (sandbox lifecycle). Registered on
      # the root CLI via `subcommand "sbx", ...`.
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

        desc "new BRANCH", "Create a sandbox for a branch that already has a worktree"
        def new(branch)
          New.new(output_mode: Orn::OutputMode.from_options(options)).run(branch)
        end

        desc "remove BRANCH", "Destroy a branch's sandbox and its persisted ports"
        def remove(branch)
          Remove.new(output_mode: Orn::OutputMode.from_options(options)).run(branch)
        end

        desc "list", "List all sandboxes on the host"
        def list
          List.new(output_mode: Orn::OutputMode.from_options(options)).run
        end

        desc "build", "Build the sandbox template image from the project's Dockerfile"
        def build
          Build.new(output_mode: Orn::OutputMode.from_options(options)).run
        end

        desc "doctor", "Diagnose the sandbox environment"
        def doctor
          Doctor.new(output_mode: Orn::OutputMode.from_options(options)).run
        end
      end
    end
  end
end
