# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require "tmpdir"

RSpec.describe Orn::Commands::SwitchSandbox do
  let(:output_mode) { Orn::OutputMode.quiet }

  # A project directory with a git identity in .bare/config (so preflight's
  # identity check passes) and a private XDG data dir for trust approvals.
  # The configured session name "proj" makes the sandbox name "proj-feat".
  def sbx_project(config_yaml)
    root = register_temp_dir(Dir.mktmpdir("orn-sbx-switch"))
    FileUtils.mkdir_p(File.join(root, ".orn"))
    FileUtils.mkdir_p(File.join(root, ".bare"))
    write_bare_git_identity(root)
    File.write(File.join(root, ".orn", "config.yaml"), config_yaml)
    ENV["XDG_DATA_HOME"] = register_temp_dir(Dir.mktmpdir("orn-sbx-data"))
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  def write_bare_git_identity(root)
    config_path = File.join(
      root,
      ".bare",
      "config"
    )
    git(
      "config",
      "--file",
      config_path,
      "user.name",
      "T"
    )
    git(
      "config",
      "--file",
      config_path,
      "user.email",
      "t@t.com"
    )
  end

  # Records the sbx-command approval the way an earlier interactive run would
  # have, so the trust check passes without a prompt.
  def approve_sbx_commands(project)
    approved_dir = File.join(
      ENV.fetch("XDG_DATA_HOME"),
      "orn",
      "approved"
    )
    approval_path = File.join(approved_dir, "sbx-#{Orn::Trust.project_id(project.root)}")
    Orn::Trust.save_approval(approval_path, Orn::Trust.sbx_fingerprint(project.config.sbx))
  end

  def feat_path(project)
    project.worktree_path("feat")
  end

  def pick_free_port
    probe_server = TCPServer.new("127.0.0.1", 0)
    port = probe_server.addr[1]
    probe_server.close
    port
  end

  # verify_port really connects to the published host port, so a listener must
  # appear once `sbx ports --publish` has run (reserve_port needs the port free
  # until then). This wrapper opens one at that moment and otherwise delegates
  # to the scripted fake.
  def listen_after_publish(fake_backend, host_port, listeners)
    wrapper = Object.new
    wrapper.define_singleton_method(:capture) do |command, **options|
      result = fake_backend.capture(command, **options)
      listeners << TCPServer.new("127.0.0.1", host_port) if command.first(2) == %w[sbx ports]
      result
    end
    Orn::Cmd.backend = wrapper
  end

  # tmux -V is dropped: the version warning runs once per process, so whether
  # it appears depends on which spec file ran first.
  def ordered_invocations(fake)
    fake.invocations.reject { |argv| argv == ["tmux", "-V"] }
  end

  # --- Command lines ---

  # The git identity check probes user.name and user.email through Cmd, so
  # preflight's invocation list includes both `git config` lookups.
  def git_identity_argvs(project)
    config_path = File.join(
      project.root,
      ".bare",
      "config"
    )
    [
      ["git", "config", "--file", config_path, "user.name"],
      ["git", "config", "--file", config_path, "user.email"]
    ]
  end

  def preflight_argvs(project)
    [
      %w[which sbx],
      %w[which docker],
      *git_identity_argvs(project),
      %w[sbx secret ls]
    ]
  end

  def fetch_argv(root, base)
    ["git", "-C", root, "fetch", "origin", base]
  end

  def ls_remote_argv(root)
    ["git", "-C", root, "ls-remote", "--heads", "origin", "feat"]
  end

  def worktree_add_argv(root, base)
    ["git", "-C", root, "worktree", "add", "-b", "feat", File.join(root, "feat"), "origin/#{base}"]
  end

  def worktree_remove_argv(root)
    ["git", "-C", root, "worktree", "remove", "--force", File.join(root, "feat")]
  end

  def sandbox_create_argv(root)
    ["sbx", "create", "--name", "proj-feat", "claude", File.join(root, "feat"), File.join(root, ".bare")]
  end

  def setup_exec_argv
    ["sbx", "exec", "proj-feat", "--", "sh", "-c", "bundle install"]
  end

  def start_exec_argv
    ["sbx", "exec", "-d", "proj-feat", "--", "sh", "-c", "bin/serve"]
  end

  def publish_argv(host_port)
    ["sbx", "ports", "proj-feat", "--publish", "#{host_port}:3000"]
  end

  def sandbox_remove_argv
    ["sbx", "rm", "--force", "proj-feat"]
  end

  def has_session_argv
    ["tmux", "has-session", "-t", "proj"]
  end

  def new_session_argv(worktree_path)
    ["tmux", "new-session", "-d", "-s", "proj", "-n", "main", "-c", worktree_path]
  end

  def new_window_argv(worktree_path)
    ["tmux", "new-window", "-a", "-P", "-F", "\#{pane_id}", "-t", "proj:", "-n", "feat", "-c", worktree_path]
  end

  def select_window_argv
    ["tmux", "select-window", "-t", "proj:feat"]
  end

  def kill_window_argv
    ["tmux", "kill-window", "-t", "proj:feat"]
  end

  # --- Scripting helpers ---

  def script_git_identity(fake, project)
    name_argv, email_argv = git_identity_argvs(project)
    fake.script(name_argv, stdout: "T\n")
    fake.script(email_argv, stdout: "t@t.com\n")
  end

  def script_passing_preflight(fake, project)
    fake.script(%w[which sbx])
    fake.script(%w[which docker])
    script_git_identity(fake, project)
    fake.script(%w[sbx secret ls], stdout: "github\n")
  end

  # ls-remote reports the branch absent, so the worktree branches off base.
  def script_worktree_creation(fake, root, base)
    fake.script(fetch_argv(root, base))
    fake.script(ls_remote_argv(root))
    fake.script(worktree_add_argv(root, base))
  end

  # has-session is probed twice with the same argv (window creation and the
  # ensure-session guard), so one script answers both.
  def script_window_open(fake, worktree_path, session_exists:)
    fake.script(["tmux", "-V"], stdout: "tmux 3.4\n")
    fake.script(has_session_argv, status: session_exists ? 0 : 1)
    fake.script(new_session_argv(worktree_path)) unless session_exists
    fake.script(new_window_argv(worktree_path), stdout: "%1\n")
    fake.script(select_window_argv)
  end

  def script_provision_through_window(fake, project, base)
    script_passing_preflight(fake, project)
    script_worktree_creation(
      fake,
      project.root,
      base
    )
    fake.script(sandbox_create_argv(project.root))
    script_window_open(
      fake,
      feat_path(project),
      session_exists: false
    )
  end

  def script_full_provision(fake, project, host_port, listeners)
    script_provision_through_window(
      fake,
      project,
      "main"
    )
    fake.script(setup_exec_argv)
    fake.script(publish_argv(host_port))
    fake.script(start_exec_argv)
    listen_after_publish(
      fake,
      host_port,
      listeners
    )
  end

  def ports_file_path(project)
    File.join(
      project.root,
      ".orn",
      "sandbox",
      "proj-feat.ports"
    )
  end

  describe ".create_with_sandbox" do
    def provision_config(host_port)
      <<~YAML
        tmux:
          session: proj
          columns: []
        sbx:
          agent_type: claude
          setup: bundle install
          start: bin/serve
          ports:
            container: 3000
            host_range: [#{host_port}, #{host_port}]
      YAML
    end

    def start_only_config
      <<~YAML
        tmux:
          session: proj
          columns: []
        sbx:
          agent_type: claude
          start: bin/serve
      YAML
    end

    def minimal_sbx_config
      <<~YAML
        tmux:
          session: proj
          columns: []
        sbx:
          agent_type: claude
      YAML
    end

    def expected_provision_argvs(project, host_port)
      [
        *preflight_argvs(project),
        fetch_argv(project.root, "main"),
        ls_remote_argv(project.root),
        worktree_add_argv(project.root, "main"),
        sandbox_create_argv(project.root),
        setup_exec_argv,
        has_session_argv,
        has_session_argv,
        new_session_argv(feat_path(project)),
        new_window_argv(feat_path(project)),
        select_window_argv,
        publish_argv(host_port),
        start_exec_argv
      ]
    end

    it "provisions the worktree, sandbox, window, ports, and services in order" do
      host_port = pick_free_port
      project = sbx_project(provision_config(host_port))
      approve_sbx_commands(project)
      listeners = []
      with_fake_cmd do |fake|
        script_full_provision(
          fake,
          project,
          host_port,
          listeners
        )

        result = described_class.create_with_sandbox(
          output_mode,
          project,
          "feat",
          nil
        )

        aggregate_failures do
          expect(result).to have_attributes(
            branch: "feat",
            action: :created,
            base: "main",
            worktree_path: feat_path(project),
            sandbox_name: "proj-feat",
            host_ports: [
              Orn::Sandbox::PortMapping.new(
                host: host_port,
                container: 3000
              )
            ]
          )
          expect(ordered_invocations(fake)).to eq(expected_provision_argvs(project, host_port))
          expect(File).to exist(ports_file_path(project))
        end
      end
    ensure
      listeners.each(&:close)
    end

    it "raises before running anything when the sbx commands are not approved" do
      project = sbx_project(start_only_config)

      with_fake_cmd do |fake|
        expect do
          described_class.create_with_sandbox(
            output_mode,
            project,
            "feat",
            nil
          )
        end.to raise_error(Orn::Error, /untrusted sandbox commands/)
        expect(fake.invocations).to be_empty
      end
    end

    it "raises before touching git when a preflight check fails" do
      project = sbx_project(minimal_sbx_config)

      with_fake_cmd do |fake|
        fake.script(%w[which sbx])
        fake.script(%w[which docker], status: 1)
        script_git_identity(fake, project)
        fake.script(%w[sbx secret ls], stdout: "github\n")

        expect do
          described_class.create_with_sandbox(
            output_mode,
            project,
            "feat",
            nil
          )
        end.to raise_error(Orn::Error, /Preflight check failed: docker not found on PATH/)
        expect(fake.invocations).to eq(preflight_argvs(project))
      end
    end

    it "tears down the window, sandbox, and worktree when a later step fails, keeping the original error" do
      project = sbx_project(start_only_config)
      approve_sbx_commands(project)
      with_fake_cmd do |fake|
        script_provision_through_window(
          fake,
          project,
          "develop"
        )
        fake.script(
          start_exec_argv,
          stderr: "service refused to start",
          status: 1
        )
        # The first two rollback steps fail too; each is suppressed so the
        # teardown continues and the original error still surfaces.
        fake.script(
          kill_window_argv,
          stderr: "no such window",
          status: 1
        )
        fake.script(
          sandbox_remove_argv,
          stderr: "no such sandbox",
          status: 1
        )
        fake.script(worktree_remove_argv(project.root))

        expect do
          described_class.create_with_sandbox(
            output_mode,
            project,
            "feat",
            "develop"
          )
        end.to raise_error(Orn::Error, "sbx failed: service refused to start")
        expect(fake.invocations.last(3)).to eq(
          [
            kill_window_argv,
            sandbox_remove_argv,
            worktree_remove_argv(project.root)
          ]
        )
      end
    end

    it "rolls back only the worktree when sandbox creation itself fails" do
      project = sbx_project(minimal_sbx_config)
      with_fake_cmd do |fake|
        script_passing_preflight(fake, project)
        script_worktree_creation(
          fake,
          project.root,
          "main"
        )
        fake.script(
          sandbox_create_argv(project.root),
          stderr: "no such template",
          status: 1
        )
        # Even the worktree cleanup failing does not mask the original error.
        fake.script(
          worktree_remove_argv(project.root),
          stderr: "not a worktree",
          status: 1
        )

        expect do
          described_class.create_with_sandbox(
            output_mode,
            project,
            "feat",
            nil
          )
        end.to raise_error(Orn::Error, "sbx failed: no such template")
        expect(ordered_invocations(fake)).to eq(
          [
            *preflight_argvs(project),
            fetch_argv(project.root, "main"),
            ls_remote_argv(project.root),
            worktree_add_argv(project.root, "main"),
            sandbox_create_argv(project.root),
            worktree_remove_argv(project.root)
          ]
        )
      end
    end
  end

  describe ".reopen_with_sandbox" do
    def reopen_start_config
      <<~YAML
        tmux:
          session: proj
          columns: []
        sbx:
          agent_type: claude
          start: bin/serve
      YAML
    end

    def no_sbx_config
      <<~YAML
        tmux:
          session: proj
          columns: []
      YAML
    end

    def write_ports_file(root, host_port)
      sandbox_dir = File.join(
        root,
        ".orn",
        "sandbox"
      )
      FileUtils.mkdir_p(sandbox_dir)
      ports_json = JSON.generate(
        [
          {
            "host" => host_port,
            "container" => 3000
          }
        ]
      )
      File.write(File.join(sandbox_dir, "proj-feat.ports"), ports_json)
    end

    it "reopens the window and restarts the configured services" do
      project = sbx_project(reopen_start_config)
      approve_sbx_commands(project)
      with_fake_cmd do |fake|
        script_window_open(
          fake,
          feat_path(project),
          session_exists: true
        )
        fake.script(start_exec_argv)

        result = described_class.reopen_with_sandbox(
          output_mode,
          project,
          "feat",
          "proj-feat"
        )

        aggregate_failures do
          expect(result).to have_attributes(
            branch: "feat",
            action: :reopened,
            base: nil,
            worktree_path: nil,
            sandbox_name: "proj-feat",
            host_ports: []
          )
          expect(ordered_invocations(fake)).to eq(
            [
              has_session_argv,
              has_session_argv,
              new_window_argv(feat_path(project)),
              select_window_argv,
              start_exec_argv
            ]
          )
        end
      end
    end

    it "republishes the persisted port mappings" do
      project = sbx_project(no_sbx_config)
      # A live listener stands in for the sandbox service, so the real
      # verify_port probe connects instead of timing out.
      listener = TCPServer.new("127.0.0.1", 0)
      host_port = listener.addr[1]
      write_ports_file(project.root, host_port)
      with_fake_cmd do |fake|
        script_window_open(
          fake,
          feat_path(project),
          session_exists: true
        )
        fake.script(publish_argv(host_port))

        result = described_class.reopen_with_sandbox(
          output_mode,
          project,
          "feat",
          "proj-feat"
        )

        aggregate_failures do
          expect(result.host_ports).to eq(
            [
              Orn::Sandbox::PortMapping.new(
                host: host_port,
                container: 3000
              )
            ]
          )
          expect(ordered_invocations(fake)).to include(publish_argv(host_port))
        end
      end
    ensure
      listener&.close
    end
  end
end
