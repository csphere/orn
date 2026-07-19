# orn

tmux workspace manager for bare-worktree git projects. One tmux session per
project, one window per branch, and every branch checked out in its own
worktree directory. Two TUIs drive the day-to-day flow: a global hub across
all projects and a per-project dashboard. The CLI covers the same operations
for scripting and one-off use.

## The model

An orn project is a bare-worktree repo: the bare clone (object store, refs)
lives in `.bare/`, and each branch is checked out as a sibling directory via
`git worktree add`. orn maps that directory layout onto tmux:

- One tmux session per project. The session name comes from `tmux.session`
  in config, defaulting to the project directory name.
- One window per worktree, named after the branch, with panes laid out from
  config (e.g. editor, server, agent).
- The TUI itself runs in a window named `orn`, pinned first. Window order is
  `orn`, the base branch, then the other branches sorted.

```
app/                        tmux session "app"
├── .bare/                  bare git repo (object store, refs)
├── .git                    pointer file (gitdir: ./.bare)
├── .orn/config.yaml        project config
├── CLAUDE.md               orients coding agents in this layout
├── main/                   window "main"
└── feature/ABC-123/        window "feature/ABC-123"
```

`clone`, `init`, and `convert` all write the root `CLAUDE.md`. Agents
started at the project root would otherwise misread the layout: the `.git`
pointer file makes the root look like a normal repo, but it has no working
tree, so git commands only work from inside a worktree directory. The file
explains that, maps the directories above, and lists the orn commands for
switching and cleanup, so an agent lands in the right worktree instead of
fighting the layout.

Switching branches means switching tmux windows. Nothing is stashed or
rebuilt: each branch keeps its own files, running processes, and agent.

## The TUIs

### Global hub: `orn -g`

The hub is the top level: every orn project on the machine, one per row.
`orn -g` opens it from anywhere; bare `orn` outside a project does the same.
It runs in its own tmux session (`tui.session`, default `orn`); started
outside tmux it creates and attaches that session.

Projects are discovered by scanning `tui.scan_roots` (global config) for
`.bare` directories, up to `tui.scan_depth` levels deep (default 3). Rows
sort into three tiers: live sessions first (most recent activity on top),
then previously entered projects, then the rest alphabetically.

Each project row shows the session indicator (`●` live, `○` none), the
active window count, the worktree count, and an aggregate agent indicator.
Expanding a row lists its worktrees: branch, dirty marker (`✎` dirty, `✔`
clean), window indicator, ahead/behind counts against the base branch
(`2↑ 1↓`), a `⬚` badge when the window runs in a sandbox, and the agent
state.

| Key | Action |
| --- | --- |
| `j` / `k` (or arrows) | Move selection |
| `Space` | Expand or collapse a project |
| `Enter` on a project | Jump to its tmux session (created if needed) |
| `Enter` on a worktree | Open its agent pane as a tab in the hub |
| `x` | Close the current tab (pane returns home) |
| `n` / `p` | Cycle to the next / previous tab |
| `r` | Refresh |
| `q` | Quit |

Agent tabs are real panes, not copies: the worktree's agent pane is joined
into the hub window next to the sidebar (33/67 split), and returned to its
home window when the tab closes. While a tab is open, tmux-level bindings
are available: `M-o` focuses the sidebar, `M-i` the agent pane, `M-n` /
`M-p` cycle tabs.

### Project TUI: `orn`

Bare `orn` inside a project opens the project dashboard: one row per
worktree with the branch name, dirty marker, window indicator, ahead/behind
counts against the base branch, and the agent indicator.

| Key | Action |
| --- | --- |
| `j` / `k` (or arrows) | Move selection |
| `Enter` | Open the worktree's window, creating it if needed |
| `n` | New branch: prompts for a name, creates the worktree and window |
| `d` | Remove the selected worktree (asks for `y` to confirm) |
| `c` | Close the tmux window (the worktree stays on disk) |
| `r` | Refresh |
| `q` | Quit |

`n` creates the worktree from `origin/<branch>` when the branch exists on
the remote (fetched first), otherwise from the base branch, then applies
the configured symlinks and lays out the window from config.

Both TUIs share the agent indicator: red `●` blocked (waiting on input),
yellow spinner working, green `○` idle. Worktree state refreshes every few
seconds; agent state every second.

## CLI

Everything the TUIs do is also a command. Global options on every command:
`-v` / `--verbose` logs executed commands to stderr, `--json` emits
machine-readable output.

### Quick start

```bash
# Clone a repo into a new bare-worktree project
orn clone git@github.com:you/app.git --base main

# Or convert an existing repo in place / init a fresh one
orn convert
orn init --base main

cd app

# Land on a branch (creates the worktree and tmux window as needed)
orn switch feature/ABC-1234

# See all worktrees and their tmux window status
orn list

# Tear down a branch's worktree and window
orn remove feature/ABC-1234
```

### Commands

- `orn clone URL --base BRANCH`: clone a remote repo into a new
  bare-worktree project. `--base` is required.
- `orn init [--base BRANCH]`: initialize a new project in the current
  directory (base defaults to `main`).
- `orn convert [--base BRANCH]`: convert a standard git repo into a
  bare-worktree project in place (base defaults to the current branch).
- `orn switch BRANCH [--base BRANCH] [--sbx]`: land on a branch. Resolves in
  order: existing tmux window, existing worktree, remote branch, new branch
  from base. `--sbx` also creates a sandbox with port publishing and
  services.
- `orn list`: all worktrees and whether each has an open tmux window.
- `orn remove BRANCH... [--prune] [--force]`: remove worktrees and their
  tmux windows. `--prune` also deletes the local and remote branches;
  `--force` skips the confirmation prompt when pruning.
- `orn completions SHELL`: print a completion script for `bash`, `zsh`, or
  `fish`.

### `orn wt`: worktree-only operations (no tmux)

- `orn wt new BRANCH [--base BRANCH]`: create a worktree without a window.
- `orn wt open BRANCH`: resolve a branch to its worktree, creating it from
  the remote if needed.
- `orn wt list`: list the project's worktrees.
- `orn wt remove BRANCH... [--prune] [--force]`: remove worktrees.
- `orn wt link`: apply the configured symlinks to the current worktree
  (for worktrees created before the symlink config changed).

### `orn sbx`: sandboxes

A sandbox is a Docker dev container attached to a worktree, configured
under `sbx:` in project config (agent type, image, kits, ports, services).

- `orn sbx new BRANCH`: create a sandbox for a branch that already has a
  worktree.
- `orn sbx remove BRANCH`: destroy a branch's sandbox and its persisted
  ports.
- `orn sbx list`: list all sandboxes on the host.
- `orn sbx build`: build the sandbox template image from the project's
  Dockerfile.
- `orn sbx doctor`: diagnose the sandbox environment.

### `orn config`

- `orn config show`: print the effective configuration with per-value
  sources (project / global / default).
- `orn config migrate [--dry-run] [--yes] [--global] [--project]`: upgrade
  config files to the current schema version. Commands refuse to run when a
  project's config is newer than the installed orn, so upgrade orn or
  migrate as prompted.

## Configuration

YAML, in two layers: project config in `.orn/config.yaml`, global defaults
in `~/.config/orn/default.yaml` (respects `XDG_CONFIG_HOME`). Project values
win over global, which win over built-in defaults.

```yaml
# .orn/config.yaml
git:
  base: main
tmux:
  session: app                # defaults to the project directory name
  columns:                    # columns or rows, not both
    - panes: [rails server, bundle exec sidekiq]
    - panes: [redis-server, claude]
symlinks:
  base:                       # linked from the base worktree into new ones
    - .env.local
    - .claude/settings.local.json
sbx:
  agent_type: claude
  ports:
    - container: 3000
      host_range: [3001, 3100]
```

The hub reads its settings from the global config only:

```yaml
# ~/.config/orn/default.yaml
tui:
  session: orn
  scan_roots: [/Users/you/dev]    # absolute paths, no ~
  scan_depth: 3
```

`templates/config.yaml` documents the full project schema, including rows
layouts and sandbox env, resources, and setup/start commands.

## Installation

Distributed as a gem; needs Ruby 3.3 or newer (macOS system Ruby is too
old). Install the built gem attached to each GitHub Release:

```bash
gem install ./orn-<version>.gem
```

Or from a checkout:

```bash
bundle install
rake install
```

## Development

```bash
just check          # rubocop + rspec (the pre-commit gate)
just test           # suite in an unprivileged container: no network, host untouched
just test-host      # suite directly on the host (faster, less isolated)
just lint
just system-test    # full suite in a Docker-in-Docker container (git/tmux/docker/sbx)
just system-shell   # interactive shell in that container for manual testing
just test-clean     # remove the test images and cache volumes
```
