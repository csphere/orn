# orn task runner: thin wrappers over bundler/rake plus the DinD system-test
# harness. `just check` runs the pre-commit gate (rubocop + rspec).

default: check

# Lint + test, the pre-commit gate.
check: lint test

test:
    bundle exec rspec

lint:
    bundle exec rubocop

fmt:
    bundle exec rubocop --autocorrect

install:
    gem build orn.gemspec && gem install ./orn-*.gem

# Build the system-test image and run the full RSpec suite inside a privileged
# Docker-in-Docker container (git, tmux, docker, sbx all isolated from the
# host). Export DOCKER_SBX_USERNAME/DOCKER_SBX_TOKEN to enable the sbx system
# specs; without them the sbx specs self-skip. Extra args go to rspec, e.g.
# `just system-test spec/system/end_to_end_spec.rb`.
system-test *args:
    docker build -t orn-system-test -f spec/system/Dockerfile .
    docker run --rm --privileged \
        -v "$(pwd):/src" \
        -v orn-system-test-bundle:/bundle \
        -v orn-system-test-docker:/var/lib/docker \
        -e DOCKER_SBX_USERNAME \
        -e DOCKER_SBX_TOKEN \
        orn-system-test {{args}}

# Drop into an interactive shell in the system-test container for manual
# testing. dockerd is running, `orn` is on PATH, and everything happens inside
# the container so the host's git/tmux/docker are never touched.
system-shell:
    docker build -t orn-system-test -f spec/system/Dockerfile .
    docker run --rm -it --privileged \
        -v "$(pwd):/src" \
        -v orn-system-test-bundle:/bundle \
        -v orn-system-test-docker:/var/lib/docker \
        orn-system-test shell
