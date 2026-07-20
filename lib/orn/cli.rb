# frozen_string_literal: true

require "thor"

module Orn
  # The Thor command dispatcher.
  #
  # Thor is a DSL: the class-level calls below (`exit_on_failure?`,
  # `class_option`, `map`, `desc`) configure the CLI declaratively at load
  # time rather than doing work at call time. They are annotated more heavily
  # than ordinary code on purpose, so this file reads without the Thor
  # documentation open.
  #
  # Subclassing Thor is the framework's required integration point, not a
  # domain inheritance choice.
  class CLI < Thor
    # Thor calls this to decide what to do when a command raises or the user
    # makes a usage error. Returning true exits the process with a nonzero
    # status (what a CLI wants); the default, false, only warns and exits 0.
    # Thor also prints a deprecation notice if this method is not defined.
    def self.exit_on_failure?
      true
    end

    # Thor derives the program name shown in help/usage from the class name
    # (`c_l_i`); override it so help reads `orn`.
    def self.basename
      "orn"
    end

    # `class_option` declares an option available to *every* command on this
    # class (Thor's inherited/"global" options), unlike `method_option`, which
    # scopes an option to the single command defined immediately after it.
    # Inside a command the parsed values are read from the `options` hash
    # (e.g. `options[:verbose]`). `type: :boolean` generates a `--verbose`
    # (and `--no-verbose`) flag; `aliases` adds the short form.
    class_option :verbose,
      type: :boolean,
      aliases: "-v",
      desc: "Log executed commands to stderr"
    class_option :json,
      type: :boolean,
      desc: "Emit machine-readable JSON output"

    # `map` aliases invocation tokens to a command name: both `orn --version`
    # and `orn -V` dispatch to the `version` command below. The key is the
    # array of spellings a user can type; the value is the command's method
    # name as a symbol. This adds `--version`/`-V` spellings,
    # which Thor does not provide out of the box.
    map %w[--version -V] => :version

    # `desc` registers the one-line summary shown by `orn help` AND is what
    # makes the *following* public method an invokable command: Thor prints a
    # warning and skips any public method that has no preceding `desc` (define
    # plain helper methods inside a `no_commands { ... }` block instead). The
    # first argument is the usage string (command name plus any args), the
    # second the description.
    desc "version", "Print the orn version"
    def version
      puts "orn #{Orn::VERSION}"
    end

    # `option` (Thor's method-level option) declares an option scoped to the
    # single command that follows. `required: true` makes `--base` mandatory.
    desc "clone URL", "Clone a remote repository into a new bare-worktree project"
    option :base,
      required: true,
      desc: "Base branch for the project"
    def clone(url)
      Orn::Commands::Clone.new(output_mode: Orn::OutputMode.from_options(options)).run(url, options[:base])
    end

    desc "init", "Initialize a new bare-worktree project in the current directory"
    option :base,
      default: "main",
      desc: "Base branch for the project"
    def init
      Orn::Commands::Init.new(output_mode: Orn::OutputMode.from_options(options)).run(options[:base])
    end

    desc "convert", "Convert the current directory's git repo into a bare-worktree project in place"
    option :base, desc: "Base branch (defaults to the current branch)"
    def convert
      Orn::Commands::Convert.new(output_mode: Orn::OutputMode.from_options(options)).run(options[:base])
    end

    desc "switch BRANCH", "Switch to a branch's tmux window, creating the worktree if needed"
    option :base, desc: "Base branch (defaults to config or 'main')"
    option :sbx,
      type: :boolean,
      default: false,
      desc: "Also create a sandbox with port publishing and services"
    def switch(branch)
      Orn::Commands::Switch.new(output_mode: Orn::OutputMode.from_options(options))
        .run(branch,
          base_override: options[:base],
          sbx: options[:sbx])
    end

    # `hide` keeps these deprecated aliases out of help; both warn and delegate
    # to `switch`. `open` takes no base/sandbox options (matching the original).
    desc "new BRANCH",
      "Deprecated: use `orn switch` instead",
      hide: true
    option :base, desc: "Base branch (defaults to config or 'main')"
    option :sbx,
      type: :boolean,
      default: false
    def new(branch)
      warn "warning: `orn new` is deprecated, use `orn switch` instead"
      Orn::Commands::Switch.new(output_mode: Orn::OutputMode.from_options(options))
        .run(branch,
          base_override: options[:base],
          sbx: options[:sbx])
    end

    desc "open BRANCH",
      "Deprecated: use `orn switch` instead",
      hide: true
    def open(branch)
      warn "warning: `orn open` is deprecated, use `orn switch` instead"
      Orn::Commands::Switch.new(output_mode: Orn::OutputMode.from_options(options)).run(branch)
    end

    desc "list", "List all worktrees and whether each has an open tmux window"
    def list
      Orn::Commands::List.new(output_mode: Orn::OutputMode.from_options(options)).run
    end

    desc "remove BRANCH [BRANCH ...]", "Remove worktrees and their tmux windows (with --prune, also their branches)"
    option :prune,
      type: :boolean,
      default: false,
      desc: "Also delete the local and remote branches"
    option :force,
      type: :boolean,
      default: false,
      desc: "Skip the confirmation prompt when pruning"
    def remove(*branches)
      raise Orn::Error, "remove requires at least one branch" if branches.empty?

      Orn::Commands::Remove.new(output_mode: Orn::OutputMode.from_options(options))
        .run(branches,
          prune: options[:prune],
          force: options[:force])
    end

    # `subcommand` registers a nested Thor class as a command group, so
    # `orn config <cmd>` dispatches into Orn::Commands::Config::CLI.
    desc "config SUBCOMMAND", "Inspect and manage configuration"
    subcommand "config", Orn::Commands::Config::CLI

    desc "wt SUBCOMMAND", "Manage git worktrees"
    subcommand "wt", Orn::Commands::Wt::CLI

    desc "sbx SUBCOMMAND", "Manage sandboxes (sbx microVMs) for worktrees"
    subcommand "sbx", Orn::Commands::Sbx::CLI

    desc "completions SHELL", "Print a shell completion script (bash, zsh, or fish)"
    def completions(shell)
      puts Orn::Completions.script(shell)
    end

    # Hidden candidate lister for the completion scripts. `exe/orn` short-
    # circuits `orn complete` before loading Thor for speed; this arm is the
    # fallback when it is reached through the full CLI.
    desc "complete",
      "List dynamic completion candidates",
      hide: true
    def complete(*)
      Orn::Complete.print_candidates
    end
  end
end
