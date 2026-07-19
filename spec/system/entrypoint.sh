#!/usr/bin/env bash
set -euo pipefail

# Test entrypoint for orn. Two modes:
#
#   unit [rspec args]    `just test`: unprivileged, no network. Prepare the
#                        test user and run RSpec against the baked-in gem
#                        bundle. Sandbox system specs self-skip (no docker).
#
#   [shell | rspec args] `just system-test` / `just system-shell`: privileged
#                        DinD. Start dockerd, authenticate sbx when
#                        credentials are present, then run RSpec (or drop
#                        into an interactive shell).
#
# Either way everything happens inside the container, so the host's git,
# tmux, and Docker state are never touched.

# --- Configure git identity for testuser ---

su -l testuser -c 'git config --global user.name "System Test"'
su -l testuser -c 'git config --global user.email "test@system.test"'

# --- Expose `orn` on PATH ---
#
# The bare-worktree layout means `gem build` (git ls-files) is unavailable in
# the container, so instead of installing the gem we wrap the mounted source:
# `orn` runs exe/orn under bundler, which puts lib/ and thor on the load path.

cat > /usr/local/bin/orn <<'WRAPPER'
#!/usr/bin/env bash
exec bundle exec ruby /src/exe/orn "$@"
WRAPPER
chmod +x /usr/local/bin/orn

# --- Unit mode: no dockerd, no network ---
#
# Gems were baked into /bundle at image build time. `bundle check` catches a
# Gemfile.lock that changed after the build; `just test` rebuilds the image
# first, so this only trips when running the container by hand.

if [ "${1:-}" = "unit" ]; then
    shift
    # /src is mounted read-only in this mode, so rspec's status file (which
    # backs --only-failures) moves to the throwaway /tmp. `su -l` scrubs the
    # environment, so COVERAGE is re-exported into the command; `just
    # coverage` mounts a writable /coverage for the SimpleCov report.
    coverage_env=""
    if [ -n "${COVERAGE:-}" ]; then
        coverage_env="COVERAGE=1 ORN_COVERAGE_DIR=/coverage"
    fi
    exec su -l testuser -c "cd /src \
        && (bundle check >/dev/null \
            || { echo 'ERROR: baked gems do not match Gemfile.lock; rebuild the image (just test does this)' >&2; exit 1; }) \
        && ORN_RSPEC_STATUS_FILE=/tmp/rspec_status ${coverage_env} bundle exec rspec ${*}"
fi

# --- Start Docker daemon (root) ---

dockerd &>/var/log/dockerd.log &

remaining=30
while [ ! -S /var/run/docker.sock ] && [ "$remaining" -gt 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
done

remaining=30
while ! docker info &>/dev/null && [ "$remaining" -gt 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
done

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon failed to start" >&2
    cat /var/log/dockerd.log >&2
    exit 1
fi

# --- Open /dev/kvm for the test user ---
#
# Docker Sandboxes runs each sandbox in a microVM, so sbx needs /dev/kvm.
# The privileged container exposes it root-owned with a host group id; the
# chmod affects only this container's /dev, never the host's node.

[ -e /dev/kvm ] && chmod 666 /dev/kvm

# --- Docker Sandboxes authentication ---
#
# sbx needs a Docker account to create sandboxes. Without credentials the
# sandbox system tests self-disable (ORN_SYSTEM_TEST stays unset) so the rest
# of the suite still runs.

system_test_env=""
if [ -n "${DOCKER_SBX_USERNAME:-}" ] && [ -n "${DOCKER_SBX_TOKEN:-}" ]; then
    printf '%s' "$DOCKER_SBX_TOKEN" \
        | su testuser -c "sbx login --username '$DOCKER_SBX_USERNAME' --password-stdin"
    # sbx refuses to create sandboxes until a global network policy exists
    # (initializing it also starts the per-user sandboxd daemon). The
    # container is throwaway and isolated, so allow-all is fine here.
    su testuser -c "sbx policy init allow-all"
    system_test_env="ORN_SYSTEM_TEST=1"
else
    echo "WARNING: DOCKER_SBX_USERNAME/DOCKER_SBX_TOKEN not set;" >&2
    echo "         skipping sbx system tests (sbx requires Docker auth)" >&2
fi

# --- Sync dependencies, then run the suite (or drop to a shell) ---
#
# `shell` (used by `just system-shell`) drops into an interactive testuser shell
# for manual testing with dockerd already up and `orn` on PATH. Otherwise run
# RSpec. ORN_IN_TEST_CONTAINER (set in testuser's login profile) enables the
# git/tmux system specs; ORN_SYSTEM_TEST additionally enables the sbx specs. Any
# extra args are forwarded to rspec (e.g. a single spec path). Gems are baked
# into the image; the runtime `bundle install` only covers Gemfile.lock drift
# since the image was built.

if [ "${1:-}" = "shell" ]; then
    exec su -l testuser -c "cd /src && bundle install --quiet; exec bash"
fi

su -l testuser -c "cd /src && bundle install --quiet && ${system_test_env} bundle exec rspec ${*}"
