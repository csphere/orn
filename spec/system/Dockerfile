# System-test image for orn: Ruby 3.3.8 + git + tmux + Docker-in-Docker + sbx.
# Uses a pinned Ruby (3.3.8) built via ruby-build.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base packages, plus everything ruby-build needs to compile a full Ruby
# (openssl, yaml/psych, readline, ffi, zlib, gdbm).
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    iptables \
    libffi-dev \
    libgdbm-dev \
    libncurses-dev \
    libreadline-dev \
    libssl-dev \
    libyaml-dev \
    lsb-release \
    pkg-config \
    sudo \
    tmux \
    uuid-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Docker Engine (for DinD)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) \
       signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu \
       $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       docker-ce docker-ce-cli containerd.io docker-sbx \
    && rm -rf /var/lib/apt/lists/*

# Ruby 3.3.8 built via ruby-build into a shared, all-user-readable location.
ENV RUBY_VERSION=3.3.8
ENV RUBY_ROOT=/usr/local/ruby
ENV PATH="${RUBY_ROOT}/bin:${PATH}"
RUN git clone --depth 1 https://github.com/rbenv/ruby-build.git /tmp/ruby-build \
    && PREFIX=/usr/local /tmp/ruby-build/install.sh \
    && ruby-build "${RUBY_VERSION}" "${RUBY_ROOT}" \
    && rm -rf /tmp/ruby-build \
    && gem install bundler --no-document \
    && chmod -R a+rwX "${RUBY_ROOT}"

# Shared bundle cache lives on a mounted volume; keep it off the source tree.
# BUNDLE_FROZEN stops the container from rewriting the host's Gemfile.lock over
# the bind mount (the lock already carries the x86_64-linux platform).
ENV BUNDLE_PATH=/bundle
ENV BUNDLE_GEMFILE=/src/Gemfile
ENV BUNDLE_FROZEN=true

# Non-root test user with Docker group membership, pinned to uid 1000 so it
# matches the host owner of the bind-mounted source (Ubuntu 24.04 ships a
# default `ubuntu` user already at 1000, so remove it first). Login shell env
# mirrors the build-time ENV so `su -l testuser` sees the same Ruby and bundle.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -s /bin/bash -u 1000 testuser \
    && usermod -aG docker testuser \
    && { \
       echo 'export PATH=/usr/local/ruby/bin:$PATH'; \
       echo 'export BUNDLE_PATH=/bundle'; \
       echo 'export BUNDLE_GEMFILE=/src/Gemfile'; \
       echo 'export BUNDLE_FROZEN=true'; \
       echo 'export ORN_IN_TEST_CONTAINER=1'; \
       } >> /home/testuser/.profile

WORKDIR /src

COPY spec/system/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
