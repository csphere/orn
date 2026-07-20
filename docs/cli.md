# orn CLI reference

Generated from the CLI definitions by `just docs`. Do not edit by
hand; CI fails when this file is out of date.

## Launching the TUIs

`orn` with no subcommand opens a TUI instead of running a command:

- `orn`: the project TUI inside a project, the global hub elsewhere
- `orn -g` / `orn --global`: the global hub from anywhere

The `-g`/`--global` flag only exists on the bare invocation; it is
not an option of any command below.

## Global options

Every command accepts:

| Option | Description |
| --- | --- |
| `-v, --verbose` | Log executed commands to stderr |
| `--json` | Emit machine-readable JSON output |

## Commands

### `orn version`

Print the orn version

### `orn clone URL`

Clone a remote repository into a new bare-worktree project

| Option | Description |
| --- | --- |
| `--base BASE` | Base branch for the project (required) |

### `orn init`

Initialize a new bare-worktree project in the current directory

| Option | Description |
| --- | --- |
| `--base BASE` | Base branch for the project (default: `main`) |

### `orn convert`

Convert the current directory's git repo into a bare-worktree project in place

| Option | Description |
| --- | --- |
| `--base BASE` | Base branch (defaults to the current branch) |

### `orn switch BRANCH`

Switch to a branch's tmux window, creating the worktree if needed

| Option | Description |
| --- | --- |
| `--base BASE` | Base branch (defaults to config or 'main') |
| `--sbx` | Also create a sandbox with port publishing and services |

### `orn list`

List all worktrees and whether each has an open tmux window

### `orn remove BRANCH [BRANCH ...]`

Remove worktrees and their tmux windows (with --prune, also their branches)

| Option | Description |
| --- | --- |
| `--prune` | Also delete the local and remote branches |
| `--force` | Skip the confirmation prompt when pruning |

### `orn completions SHELL`

Print a shell completion script (bash, zsh, or fish)

## `orn config`

Inspect and manage configuration

### `orn config show`

Print the effective configuration with per-value sources

### `orn config migrate`

Upgrade config files to the current schema version

| Option | Description |
| --- | --- |
| `--dry-run` | Preview changes without writing |
| `--global` | Migrate only the global config (~/.config/orn/default.yaml) |
| `--project` | Migrate only the project config (.orn/config.yaml) |

## `orn wt`

Manage git worktrees

### `orn wt new BRANCH`

Create a worktree for a branch (no tmux window)

| Option | Description |
| --- | --- |
| `--base BASE` | Base branch (defaults to config or 'main') |

### `orn wt open BRANCH`

Resolve a branch to its worktree, creating it from the remote if needed

### `orn wt list`

List the project's worktrees

### `orn wt remove BRANCH [BRANCH ...]`

Remove worktrees (with --prune, also their branches)

| Option | Description |
| --- | --- |
| `--prune` | Also delete the local and remote branches |
| `--force` | Skip the confirmation prompt |

### `orn wt link`

Apply the configured symlinks to the current worktree

## `orn sbx`

Manage sandboxes (sbx microVMs) for worktrees

### `orn sbx new BRANCH`

Create a sandbox for a branch that already has a worktree

### `orn sbx remove BRANCH`

Destroy a branch's sandbox and its persisted ports

### `orn sbx list`

List all sandboxes on the host

### `orn sbx build`

Build the sandbox template image from the project's Dockerfile

### `orn sbx doctor`

Diagnose the sandbox environment
