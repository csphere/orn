# sbx template for the dummy Rails app: postgres, redis, and ruby in one
# image. Built by `orn sbx build` and loaded into the sandbox runtime; the
# app itself is not copied in because sbx mounts the worktree at its host
# path.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    postgresql \
    postgresql-client \
    redis-server \
    ruby \
    && rm -rf /var/lib/apt/lists/*
