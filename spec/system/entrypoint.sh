#!/usr/bin/env bash
set -euo pipefail

# System-test entrypoint for orn. Starts a Docker daemon, prepares the test
# user, installs gem dependencies, and runs the RSpec suite inside the
# container so nothing ever touches the host's git, tmux, or Docker state.

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

# --- Fix permissions on the shared bundle cache volume ---

mkdir -p /bundle
chown -R testuser:testuser /bundle 2>/dev/null || true

# --- Open /dev/kvm for the test user ---
#
# Docker Sandboxes runs each sandbox in a microVM, so sbx needs /dev/kvm.
# The privileged container exposes it root-owned with a host group id; the
# chmod affects only this container's /dev, never the host's node.

[ -e /dev/kvm ] && chmod 666 /dev/kvm

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

# --- Install dependencies, then run the suite (or drop to a shell) ---
#
# `shell` (used by `just system-shell`) drops into an interactive testuser shell
# for manual testing with dockerd already up and `orn` on PATH. Otherwise run
# RSpec. ORN_IN_TEST_CONTAINER (set in testuser's login profile) enables the
# git/tmux system specs; ORN_SYSTEM_TEST additionally enables the sbx specs. Any
# extra args are forwarded to rspec (e.g. a single spec path).

if [ "${1:-}" = "shell" ]; then
    exec su -l testuser -c "cd /src && bundle install --quiet; exec bash"
fi

su -l testuser -c "cd /src && bundle install --quiet && ${system_test_env} bundle exec rspec ${*}"
