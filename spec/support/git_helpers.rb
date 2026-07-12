# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Test helpers for building temporary bare-worktree projects and git remotes.
# Temp dirs are tracked per example and
# removed afterwards.
module GitHelpers
  GIT_ISOLATION_ENV = {
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  # A temp dir shaped like an orn project: a `.bare` bare repo, a `.git`
  # pointer file, and an empty `.orn/` directory. Returns the root path.
  def make_bare_project
    root = register_temp_dir(Dir.mktmpdir("orn-project"))
    git("init", "--bare", File.join(root, ".bare"))
    File.write(File.join(root, ".git"), "gitdir: ./.bare\n")
    FileUtils.mkdir_p(File.join(root, ".orn"))
    root
  end

  # A bare repo usable as a remote, with `main` (containing f.txt) and
  # `branch` (adding g.txt) pushed to it. Returns the remote path.
  def make_remote_with_branch(branch)
    remote = register_temp_dir(Dir.mktmpdir("orn-remote"))
    git("init", "--bare", remote)

    workspace = register_temp_dir(Dir.mktmpdir("orn-workspace"))
    git("init", chdir: workspace)
    git("config", "user.email", "t@t.com", chdir: workspace)
    git("config", "user.name", "T", chdir: workspace)
    git("remote", "add", "origin", remote, chdir: workspace)

    File.write(File.join(workspace, "f.txt"), "x")
    git("add", ".", chdir: workspace)
    git("commit", "-m", "init", chdir: workspace)
    git("push", "origin", "HEAD:main", chdir: workspace)

    git("checkout", "-b", branch, chdir: workspace)
    File.write(File.join(workspace, "g.txt"), "y")
    git("add", ".", chdir: workspace)
    git("commit", "-m", "branch", chdir: workspace)
    git("push", "origin", branch, chdir: workspace)

    remote
  end

  def add_origin(project, remote)
    git("remote", "add", "origin", remote, chdir: project)
  end

  # Pushes a new `branch` (with a distinct commit) to an existing `remote`, via
  # a throwaway clone.
  def push_branch(remote, branch)
    workspace = register_temp_dir(Dir.mktmpdir("orn-push"))
    git("clone", remote, workspace)
    git("config", "user.email", "t@t.com", chdir: workspace)
    git("config", "user.name", "T", chdir: workspace)
    git("checkout", "-b", branch, chdir: workspace)
    File.write(File.join(workspace, "#{branch.tr("/", "-")}.txt"), "x")
    git("add", ".", chdir: workspace)
    git("commit", "-m", branch, chdir: workspace)
    git("push", "origin", branch, chdir: workspace)
    nil
  end

  # Initializes a standard (non-bare) git repo at `path` with a committer
  # identity, for tests that need a working tree with git available.
  def init_git_repo(path)
    git("init", chdir: path)
    git("config", "user.email", "t@t.com", chdir: path)
    git("config", "user.name", "T", chdir: path)
  end

  # A standard (non-bare) repo on `main` with a committed file, pushed to an
  # origin remote that is then deleted, so its origin URL dangles: conversion
  # guards (which read local refs) pass, but a re-clone from origin fails.
  def make_standard_repo
    dir = register_temp_dir(Dir.mktmpdir("orn-std"))
    seed_standard_repo(dir)
    dir
  end

  # Like make_standard_repo, but also records refs/remotes/origin/HEAD -> main.
  def make_repo_with_remote_head
    dir = register_temp_dir(Dir.mktmpdir("orn-std"))
    seed_standard_repo(dir) do
      git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main", chdir: dir)
    end
    dir
  end

  def seed_standard_repo(dir)
    remote = Dir.mktmpdir("orn-std-remote")
    git("init", "--bare", remote)
    git("init", "-b", "main", chdir: dir)
    git("config", "user.email", "t@t.com", chdir: dir)
    git("config", "user.name", "T", chdir: dir)
    git("remote", "add", "origin", remote, chdir: dir)
    File.write(File.join(dir, "file.txt"), "content")
    git("add", ".", chdir: dir)
    git("commit", "-m", "init", chdir: dir)
    git("push", "-u", "origin", "main", chdir: dir)
    yield if block_given?
    FileUtils.remove_entry(remote)
    nil
  end

  # Points the global config at a fresh dir holding an existing default.yaml, so
  # project scaffolding's global-config bootstrap skips (no interactive prompt).
  # ENV is restored per example by the env-isolation hook.
  def isolate_global_config
    xdg = register_temp_dir(Dir.mktmpdir("orn-xdg"))
    FileUtils.mkdir_p(File.join(xdg, "orn"))
    File.write(File.join(xdg, "orn/default.yaml"), "")
    ENV["XDG_CONFIG_HOME"] = xdg
  end

  # A Project rooted at `root` with the given .orn/config.yaml written and
  # loaded (project config only, no global layer, for hermetic tests).
  def make_project(root, config_yaml = "")
    FileUtils.mkdir_p(File.join(root, ".orn"))
    File.write(File.join(root, ".orn/config.yaml"), config_yaml)
    Orn::Git::Project.new(root: root, config: Orn::Config.load_from(root, nil))
  end

  def git(*args, chdir: nil)
    options = { out: File::NULL, err: File::NULL }
    options[:chdir] = chdir if chdir
    system(GIT_ISOLATION_ENV, "git", *args, **options)
  end

  def register_temp_dir(dir)
    (@git_helper_temp_dirs ||= []) << dir
    dir
  end

  def remove_temp_dirs
    Array(@git_helper_temp_dirs).each { |dir| FileUtils.remove_entry(dir, true) }
    @git_helper_temp_dirs = []
  end
end

RSpec.configure do |config|
  config.include GitHelpers
  config.after { remove_temp_dirs }
end
