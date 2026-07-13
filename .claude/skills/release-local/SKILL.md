---
name: release-local
description: >
  Rebuild the gem and reinstall it locally for development. Trigger on
  "release-local", "rebuild", "reinstall", "install locally", "build and
  install", or "update local binary".
---

# Release Local Skill

Rebuild the `orn` gem from the current working tree and reinstall it locally so
the `orn` command on your PATH reflects your latest changes. There is no compile
step.

## Step 1: Rebuild and reinstall

```
just install
```

This runs `gem build orn.gemspec` and then reinstalls the freshly built gem,
replacing any previously installed `orn`. Stop if either step fails.

## Step 2: Verify

```
orn --version
```

Confirm it reports the version from `lib/orn/version.rb`.
