# frozen_string_literal: true

# Fast-path completion candidate provider. This file requires only the minimal
# chain needed to discover the project and list its worktree branches, so a
# per-keystroke `orn complete` invocation avoids loading Thor, the TUI,
# detection, and the sandbox layer.
require_relative "error"
require_relative "output_mode"
require_relative "cmd"
require_relative "fs"
require_relative "git/branch_name"
require_relative "config/schema"
require_relative "config/validate"
require_relative "config/loader"
require_relative "config/tui"
require_relative "session"
require_relative "git/project"
require_relative "git/worktree"

module Orn
  # Dynamic shell-completion candidates. Branch arguments complete to the
  # project's existing worktree branches; nothing is offered outside a project.
  module Complete
    # The project's worktree branches, or an empty list outside a project or on
    # any discovery failure (so completion never errors at the prompt).
    def self.branch_candidates
      project = Orn::Git::Project.discover
      Orn::Git::Worktree.new(root: project.root, output_mode: Orn::OutputMode.quiet).entries
    rescue Orn::Error
      []
    end

    # Prints one candidate per line for the shell scripts to consume.
    def self.print_candidates
      puts branch_candidates
    end
  end
end
