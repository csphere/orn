# orn task runner: thin wrappers over bundler/rake plus the containerized test
# harness. `just check` runs the pre-commit gate (rubocop + rspec).

default: check

# Lint + test, the pre-commit gate.
check: lint test

# Run the whole suite in an unprivileged container: no network, no docker
# socket, read-only source mount, throwaway /tmp. The git repos, tmux
# servers, and files the tests create all live and die inside the container,
# so the suite cannot touch host state. Gems are baked into the image at
# build time; the build is cached and only reruns when the Gemfile or lock
# changes. Extra args go to rspec, e.g. `just test spec/orn/trust_spec.rb`.
test *args:
    docker build --target base -t orn-test-base -f spec/system/Dockerfile .
    docker run --rm \
        --network=none \
        --tmpfs /tmp \
        -v "$(pwd):/src:ro" \
        orn-test-base unit {{args}}

# Like `just test`, but with SimpleCov enabled; the HTML report lands in
# ./coverage on the host (the one writable mount the container gets).
coverage *args:
    docker build --target base -t orn-test-base -f spec/system/Dockerfile .
    mkdir -p coverage
    docker run --rm \
        --network=none \
        --tmpfs /tmp \
        -v "$(pwd):/src:ro" \
        -v "$(pwd)/coverage:/coverage" \
        -e COVERAGE=1 \
        orn-test-base unit {{args}}

# Run the suite directly on the host. The spec harness still fakes stdin,
# HOME, and subprocess spawns per example, but prefer `just test` for full
# isolation. `COVERAGE=1 just test-host` writes ./coverage without a
# container.
test-host *args:
    bundle exec rspec {{args}}

lint:
    bundle exec rubocop

fmt:
    bundle exec rubocop --autocorrect

install:
    gem build orn.gemspec && gem install --force ./orn-*.gem

# Build the test image and run the full RSpec suite inside a privileged
# Docker-in-Docker container (git, tmux, docker, sbx all isolated from the
# host; --privileged shares the kernel, so this isolates state, it is not a
# security boundary). Export DOCKER_SBX_USERNAME/DOCKER_SBX_TOKEN to enable
# the sbx system specs; without them the sbx specs self-skip. Extra args go
# to rspec, e.g. `just system-test spec/system/end_to_end_spec.rb`.
system-test *args:
    docker build -t orn-test -f spec/system/Dockerfile .
    docker run --rm --privileged \
        -v "$(pwd):/src" \
        -v orn-system-test-docker:/var/lib/docker \
        -e DOCKER_SBX_USERNAME \
        -e DOCKER_SBX_TOKEN \
        orn-test {{args}}

# Drop into an interactive shell in the system-test container for manual
# testing. dockerd is running, `orn` is on PATH, and everything happens inside
# the container so the host's git/tmux/docker are never touched.
system-shell:
    docker build -t orn-test -f spec/system/Dockerfile .
    docker run --rm -it --privileged \
        -v "$(pwd):/src" \
        -v orn-system-test-docker:/var/lib/docker \
        orn-test shell

# Remove the test images and cache volumes the harness leaves on the host's
# docker daemon.
test-clean:
    docker rmi orn-test orn-test-base 2>/dev/null || true
    docker volume rm orn-system-test-bundle orn-system-test-docker 2>/dev/null || true
