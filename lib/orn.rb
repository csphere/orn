# frozen_string_literal: true

require_relative "orn/version"
require_relative "orn/error"
require_relative "orn/output_mode"
require_relative "orn/cmd"
require_relative "orn/template"
require_relative "orn/git/branch_name"
require_relative "orn/tui"
require_relative "orn/cli"
require_relative "orn/shim"

# Top-level namespace for orn, a git worktree and tmux workspace manager.
module Orn
  # Absolute path to the gem root, used to locate bundled templates.
  def self.root
    File.expand_path("..", __dir__)
  end
end
