# frozen_string_literal: true

require "open3"
require "pty"
require "json"
require "tmpdir"
require "fileutils"

# Shared plumbing for the sandbox system specs (spec/system/sandbox_*): an
# isolated environment (XDG config and data dirs), a project cloned from a
# local bare remote, and helpers that drive the real `orn` executable,
# including through a pseudo-terminal for the trust-approval prompt.
#
# Including specs define `let(:branch)`; `session` and `sandbox_name` derive
# unique names from it so runs never collide on the shared docker state.
RSpec.shared_context "with a sandbox system project" do
  let(:xdg_config) { Dir.mktmpdir("orn-sbx-config") }
  let(:xdg_data) { Dir.mktmpdir("orn-sbx-data") }
  let(:workspace) { Dir.mktmpdir("orn-sbx-workspace") }
  let(:session) { "orn-sbx-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}" }
  let(:sandbox_name) { "#{session}-#{branch.gsub(/[^a-zA-Z0-9-]/, "-")}" }

  # Pre-seed an empty global config so project scaffolding skips its
  # interactive bootstrap; XDG_DATA_HOME isolates trust approvals and state.
  # The isolation must not hide the sbx CLI's own state from orn's
  # subprocesses: sbx keeps its Docker auth and settings under
  # XDG_CONFIG_HOME (com.docker.sandboxes, sandboxes) and more state under
  # XDG_DATA_HOME, so the real dirs are symlinked into the isolated homes.
  before do
    FileUtils.mkdir_p(File.join(xdg_config, "orn"))
    File.write(File.join(xdg_config, "orn", "default.yaml"), "")
    link_sbx_state(File.expand_path("~/.config"), xdg_config, %w[com.docker.sandboxes sandboxes])
    link_sbx_state(File.expand_path("~/.local/share"), xdg_data, %w[sandboxes])
  end

  # Best-effort teardown so a failed example does not leak a sandbox or tmux
  # session into later examples (docker state is shared across runs). Guarded
  # by the sbx gate's env var: hooks also run for skipped examples, and a
  # skipped one must not touch the host's sbx or tmux at all.
  after do
    if ENV["ORN_SYSTEM_TEST"] == "1"
      system(
        "sbx",
        "rm",
        "--force",
        sandbox_name,
        out: File::NULL,
        err: File::NULL
      )
      system(
        "tmux",
        "kill-session",
        "-t",
        session,
        out: File::NULL,
        err: File::NULL
      )
    end
    [xdg_config, xdg_data, workspace].each { |dir| FileUtils.remove_entry(dir, true) }
  end

  def orn_env
    {
      "XDG_CONFIG_HOME" => xdg_config,
      "XDG_DATA_HOME" => xdg_data
    }
  end

  def link_sbx_state(real_base, isolated_base, dir_names)
    dir_names.each do |dir_name|
      source_dir = File.join(real_base, dir_name)
      FileUtils.ln_s(source_dir, File.join(isolated_base, dir_name)) if File.exist?(source_dir)
    end
  end

  def orn(*args, chdir:)
    Open3.capture3(orn_env, "orn", *args.map(&:to_s), chdir: chdir)
  end

  # Runs orn and asserts success, returning stdout.
  def orn_ok(*args, chdir:)
    stdout, stderr, status = orn(*args, chdir: chdir)
    expect(status).to be_success, "orn #{args.join(" ")} failed: #{stderr}"
    stdout
  end

  # Runs orn with --json and parses its output, failing the example with
  # stderr when the command itself fails.
  def orn_json(*args, chdir:)
    stdout, stderr, status = orn("--json", *args, chdir: chdir)
    expect(status).to be_success, "orn --json #{args.join(" ")} failed: #{stderr}"
    JSON.parse(stdout)
  end

  # Runs orn through a pseudo-terminal so the trust prompt sees an
  # interactive session; `input` answers the prompt. Returns the combined
  # terminal output and the exit status.
  def orn_pty(*args, chdir:, input:)
    output = +""
    status = nil
    PTY.spawn(orn_env, "orn", *args.map(&:to_s), chdir: chdir) do |reader, writer, pid|
      writer.write(input)
      begin
        loop { output << reader.readpartial(4096) }
      rescue Errno::EIO, EOFError
        # The terminal closes when the command exits.
      end
      _, status = Process.wait2(pid)
    end
    [output, status]
  end

  # A local bare remote whose main branch carries `seed_dir`'s contents (or a
  # single seed file when none is given). Committer identity comes from the
  # container's git config.
  def make_remote(seed_dir = nil)
    remote_path = File.join(workspace, "app.git")
    run_ok("git", "init", "--bare", "--initial-branch", "main", remote_path)

    checkout = File.join(workspace, "seed")
    FileUtils.mkdir_p(checkout)
    if seed_dir
      # preserve keeps the executable bit on any bin/ scripts in the seed.
      FileUtils.cp_r("#{seed_dir}/.", checkout, preserve: true)
    else
      File.write(File.join(checkout, "seed.txt"), "seed\n")
    end
    run_ok("git", "init", chdir: checkout)
    run_ok("git", "add", ".", chdir: checkout)
    run_ok("git", "commit", "-m", "seed", chdir: checkout)
    run_ok("git", "push", remote_path, "HEAD:main", chdir: checkout)
    remote_path
  end

  # Clones the remote into the workspace as a bare-worktree project, replaces
  # the scaffolded config, and sets the in-repo git identity the sandbox
  # preflight requires. Returns the project root.
  def clone_project(remote_path, config_yaml)
    _stdout, stderr, status = orn("clone", remote_path, "--base", "main", chdir: workspace)
    expect(status).to be_success, "orn clone failed: #{stderr}"

    project_root = File.join(workspace, "app")
    File.write(File.join(project_root, ".orn", "config.yaml"), config_yaml)
    bare_config = File.join(project_root, ".bare", "config")
    run_ok("git", "config", "--file", bare_config, "user.name", "System Test")
    run_ok("git", "config", "--file", bare_config, "user.email", "test@system.test")
    project_root
  end

  # Sandbox names reported by `orn sbx list`.
  def listed_sandbox_names(project_root)
    orn_json("sbx", "list", chdir: project_root).fetch("sandboxes").map { |sandbox| sandbox["name"] }
  end

  def tmux_window_names(session_name)
    stdout, _stderr, status = Open3.capture3("tmux", "list-windows", "-t", session_name, "-F", "\#{window_name}")
    status.success? ? stdout.lines.map(&:strip) : []
  end

  # Polls the block once a second until it returns true or `timeout` seconds
  # pass; returns whether it ever did.
  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 1
    end
  end

  def run_ok(*command, chdir: workspace)
    stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
    expect(status).to be_success, "#{command.join(" ")} failed: #{stderr}"
    stdout
  end
end
