# Bare worktree workspace: {project_name}

This project uses the bare worktree pattern, managed by [orn](https://github.com/seaseducation/orn).

## How bare worktrees work

Standard git repos have a `.git/` directory inside a single working tree. This project inverts that: a bare clone (no working tree) lives in `.bare/`, and a `.git` pointer file (`gitdir: ./.bare`) at the project root makes the directory look like a repo to git tooling. Worktrees are added as sibling directories via `git worktree add`. Each worktree gets its own `.git` pointer file that references `.bare/worktrees/<name>`.

This gives every branch a dedicated directory on disk with full filesystem isolation, while sharing a single object store and ref database.

**Important:** git commands must run from inside a worktree directory, not the project root.

## Layout

```
{project_name}/
├── .bare/          # bare git repo (object store, refs)
├── .git            # pointer file (gitdir: ./.bare)
├── .orn/           # orn config
│   └── config.yaml
├── {base}/         # base branch worktree
├── feature/xyz/    # feature branch worktree (example)
└── CLAUDE.md       # this file
```

## orn conventions

- `orn clone <url> --base <branch>` clones a repo into a bare worktree project.
- `.orn/` holds project configuration (`config.yaml`).
- `orn switch <branch>` switches to a branch, creating the worktree if needed.
- `orn remove <branch>` cleans up the worktree and tmux window.
- `orn list` shows all worktrees and their status.
