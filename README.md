# orn

A git worktree and tmux workspace manager. `orn` gives every branch its own
worktree directory and a dedicated tmux window laid out from config, with
optional dev-container sandboxes and agent detection. Config is YAML.

## What it does

`orn` manages the bare-worktree pattern: a bare git clone lives in `.bare/`, and
every branch gets its own worktree directory as a sibling, sharing one object
store. Each worktree can have a dedicated tmux window laid out from config, an
optional sandbox (dev container), and a blackboard for agent coordination.

## Installation

`orn` is distributed as a gem and needs Ruby 3.3 or newer. macOS system Ruby
(2.6) is too old; use rbenv, asdf, or Homebrew Ruby.

Install the built gem (attached to each GitHub Release):

```bash
gem install ./orn-<version>.gem
```

Or from a checkout:

```bash
bundle install
rake install      # or: gem build orn.gemspec && gem install ./orn-*.gem
```

Verify:

```bash
orn --version
```

## Quick start

```bash
# Clone a repo into a new bare-worktree project
orn clone git@github.com:you/app.git --base main

# Or convert an existing repo in place / init a fresh one
orn convert
orn init --base main

cd app

# Land on a branch (creates the worktree + tmux window as needed)
orn switch feature/ABC-1234

# See all worktrees and their tmux window status
orn list

# Clean up a branch's worktree and window (add --prune to delete the branch)
orn remove feature/ABC-1234
```

Run bare `orn` to open the project TUI, or `orn -g` for the global hub across
all discovered projects.

## Configuration

Configuration is YAML. Project config lives in `.orn/config.yaml`; global
defaults in `~/.config/orn/default.yaml` (respecting `XDG_CONFIG_HOME`). Project
values win over global, which win over built-in defaults.

```yaml
# .orn/config.yaml
git:
  base: main
tmux:
  session: work-api
  columns:
    - panes: [rails server, bundle exec sidekiq]
    - panes: [redis-server, claude]
symlinks:
  base:
    - .env.local
    - .claude/settings.local.json
```

Inspect the effective config with source annotations:

```bash
orn config show
orn config migrate      # upgrade config files to the current schema version
```

## Commands

- `orn clone|init|convert` — create a bare-worktree project
- `orn switch <branch>` — land on a branch (window, worktree, remote, or new)
- `orn list` / `orn remove <branch>...` — inspect and tear down worktrees
- `orn wt <new|open|list|remove|link>` — worktree-only operations (no tmux)
- `orn sbx <new|remove|list|build|doctor>` — sandbox (dev container) lifecycle
- `orn config <show|migrate>` — inspect and migrate configuration
- `orn completions <bash|zsh|fish>` — print a shell completion script

## Development

```bash
just check          # rubocop + rspec (the pre-commit gate)
just test
just lint
just system-test    # full suite in a Docker-in-Docker container (git/tmux/docker)
```
