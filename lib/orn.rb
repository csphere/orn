# frozen_string_literal: true

require_relative "orn/version"
require_relative "orn/error"
require_relative "orn/output_mode"
require_relative "orn/cmd"
require_relative "orn/template"
require_relative "orn/fs"
require_relative "orn/git/branch_name"
require_relative "orn/git/project"
require_relative "orn/git/worktree"
require_relative "orn/config/schema"
require_relative "orn/config/validate"
require_relative "orn/config/loader"
require_relative "orn/config/tui"
require_relative "orn/session"
require_relative "orn/symlink"
require_relative "orn/confirm"
require_relative "orn/blackboard"
require_relative "orn/commands/output"
require_relative "orn/commands/setup"
require_relative "orn/commands/clone"
require_relative "orn/commands/init"
require_relative "orn/commands/convert"
require_relative "orn/commands/config/show"
require_relative "orn/commands/config/cli"
require_relative "orn/commands/wt/list"
require_relative "orn/commands/wt/cli"
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
