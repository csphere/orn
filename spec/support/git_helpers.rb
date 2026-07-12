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
