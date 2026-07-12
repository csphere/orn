# Blackboard Protocol

Shared coordination surface for agents working in parallel across worktrees.

## Location

Each branch gets a blackboard at `.orn/blackboard/<branch-path>/blackboard.md`, created from the template at `.orn/blackboard/TEMPLATE.md`.

## Sections

- **Status**: current state of work on this branch
- **Files Modified**: files created, changed, or deleted
- **Interface Changes**: public API surface changes (structs, traits, functions, CLI flags)
- **Dependencies**: crate/package changes, feature flags
- **Decisions**: architectural choices and rationale
- **Warnings**: merge conflict risks, contradictions, hazards for other agents

## Write protocol

Update your blackboard entry when you change shared state: public interfaces, dependencies, or files likely touched by other branches. Set Status to `starting` when you begin and `done` when you finish. Keep entries succinct; other agents scan these quickly. A few precise lines beat a wall of text.

## Read protocol

Check the blackboard:
1. On startup, before beginning work
2. Before editing files that other branches may also touch
3. Before rebasing or creating a PR (compare your file list against active branches)

To check for overlap before a PR: list your changed files, scan other branches' Files Modified sections, and run targeted diffs on any overlap.

## Conflict response

- **File overlap** (same file modified by multiple branches): adapt your changes to accommodate, rebase if needed
- **Interface or dependency conflict** (incompatible API changes, version conflicts): stop and escalate to the user
