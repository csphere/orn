# frozen_string_literal: true

module Orn
  # Hand-written shell completion scripts (bash/zsh/fish). Thor has no
  # completion generator, so these are maintained by hand. Dynamic branch
  # completion defers to `orn complete`, which prints the project's worktree
  # branches one per line.
  module Completions
    SHELLS = %w[bash zsh fish].freeze

    # Top-level commands and subcommand groups, shared across the scripts.
    TOP_COMMANDS = %w[clone init convert switch list remove config wt sbx mcp setup completions help].freeze
    WT_SUBCOMMANDS = %w[new open list remove link].freeze
    SBX_SUBCOMMANDS = %w[new remove list build doctor].freeze
    CONFIG_SUBCOMMANDS = %w[show migrate].freeze
    # Commands whose positional argument is a branch name.
    BRANCH_COMMANDS = %w[switch remove].freeze

    # The completion script for `shell`.
    def self.script(shell)
      case shell
      when "bash" then bash
      when "zsh" then zsh
      when "fish" then fish
      else raise Orn::Error, "Unsupported shell: #{shell} (expected one of #{SHELLS.join(", ")})"
      end
    end

    def self.bash
      <<~BASH
        # orn bash completion. Source this file or install it in your
        # bash-completion.d directory.
        _orn() {
          local cur prev
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"

          if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "-v --verbose --json --version -g --global --help" -- "$cur") )
            return
          fi

          case "${COMP_WORDS[1]}" in
            wt)
              if [[ "$COMP_CWORD" -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{WT_SUBCOMMANDS.join(" ")}" -- "$cur") )
              elif [[ "${COMP_WORDS[2]}" =~ ^(new|open|remove)$ ]]; then
                COMPREPLY=( $(compgen -W "$(orn complete)" -- "$cur") )
              fi
              return ;;
            sbx)
              if [[ "$COMP_CWORD" -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "#{SBX_SUBCOMMANDS.join(" ")}" -- "$cur") )
              elif [[ "${COMP_WORDS[2]}" =~ ^(new|remove)$ ]]; then
                COMPREPLY=( $(compgen -W "$(orn complete)" -- "$cur") )
              fi
              return ;;
            config)
              [[ "$COMP_CWORD" -eq 2 ]] && COMPREPLY=( $(compgen -W "#{CONFIG_SUBCOMMANDS.join(" ")}" -- "$cur") )
              return ;;
            switch|remove|new|open)
              COMPREPLY=( $(compgen -W "$(orn complete)" -- "$cur") )
              return ;;
          esac

          if [[ "$COMP_CWORD" -eq 1 ]]; then
            COMPREPLY=( $(compgen -W "#{TOP_COMMANDS.join(" ")}" -- "$cur") )
          fi
        }
        complete -F _orn orn
      BASH
    end

    def self.zsh
      <<~ZSH
        #compdef orn
        # orn zsh completion. Place this file on your $fpath as _orn.
        _orn() {
          local -a top wt sbx conf
          top=(#{TOP_COMMANDS.join(" ")})
          wt=(#{WT_SUBCOMMANDS.join(" ")})
          sbx=(#{SBX_SUBCOMMANDS.join(" ")})
          conf=(#{CONFIG_SUBCOMMANDS.join(" ")})

          if (( CURRENT == 2 )); then
            compadd -- $top
            return
          fi

          case "${words[2]}" in
            wt)
              (( CURRENT == 3 )) && { compadd -- $wt; return }
              [[ "${words[3]}" == (new|open|remove) ]] && compadd -- ${(f)"$(orn complete)"}
              ;;
            sbx)
              (( CURRENT == 3 )) && { compadd -- $sbx; return }
              [[ "${words[3]}" == (new|remove) ]] && compadd -- ${(f)"$(orn complete)"}
              ;;
            config)
              (( CURRENT == 3 )) && compadd -- $conf
              ;;
            switch|remove|new|open)
              compadd -- ${(f)"$(orn complete)"}
              ;;
          esac
        }
        compdef _orn orn
      ZSH
    end

    def self.fish
      <<~FISH
        # orn fish completion. Place this file in ~/.config/fish/completions/orn.fish
        function __orn_needs_command
          set -l cmd (commandline -opc)
          test (count $cmd) -eq 1
        end

        function __orn_using_command
          set -l cmd (commandline -opc)
          test (count $cmd) -ge 2; and test "$cmd[2]" = "$argv[1]"
        end

        complete -c orn -f
        complete -c orn -n __orn_needs_command -a "#{TOP_COMMANDS.join(" ")}"
        complete -c orn -n "__orn_using_command switch" -a "(orn complete)"
        complete -c orn -n "__orn_using_command remove" -a "(orn complete)"
        complete -c orn -n "__orn_using_command wt" -a "#{WT_SUBCOMMANDS.join(" ")}"
        complete -c orn -n "__orn_using_command sbx" -a "#{SBX_SUBCOMMANDS.join(" ")}"
        complete -c orn -n "__orn_using_command config" -a "#{CONFIG_SUBCOMMANDS.join(" ")}"
        complete -c orn -l verbose -s v -d "Log executed commands to stderr"
        complete -c orn -l json -d "Emit machine-readable JSON output"
      FISH
    end

    private_class_method :bash, :zsh, :fish
  end
end
