# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require "tmpdir"

RSpec.describe Orn::Commands::Sbx::New do
  let(:command) { described_class.new(output_mode: Orn::OutputMode.default) }

  def project_with(config)
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx")), config)
  end

  # A bare project whose preflight passes for real: a git identity in
  # .bare/config, isolated XDG config and data dirs, and an existing worktree
  # at feat/. The configured session name "proj" makes the sandbox name
  # "proj-feat".
  def sandbox_ready_project(config_yaml)
    root = File.realpath(make_bare_project)
    write_bare_git_identity(root)
    File.write(File.join(root, ".orn", "config.yaml"), config_yaml)
    FileUtils.mkdir_p(File.join(root, "feat"))
    isolate_global_config
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

  # --- Config fixtures ---

  def full_config(host_port)
    <<~YAML
      tmux:
        session: proj
        columns: []
      sbx:
        agent_type: claude
        template: img:1
        setup: bundle install
        ports:
          container: 3000
          host_range: [#{host_port}, #{host_port}]
    YAML
  end

  def minimal_config
    <<~YAML
      tmux:
        session: proj
        columns: []
      sbx:
        agent_type: claude
    YAML
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

  # With a template configured, preflight also checks `sbx template ls`
  # between the identity check and the github secret check.
  def template_preflight_argvs(project)
    [
      %w[which sbx],
      %w[which docker],
      *git_identity_argvs(project),
      %w[sbx template ls],
      %w[sbx secret ls]
    ]
  end

  def inspect_argv
    %w[sbx inspect proj-feat]
  end

  def create_argv(project)
    [
      "sbx",
      "create",
      "--name",
      "proj-feat",
      "-t",
      "img:1",
      "claude",
      File.join(project.root, "feat"),
      File.join(project.root, ".bare")
    ]
  end

  def minimal_create_argv(project)
    [
      "sbx",
      "create",
      "--name",
      "proj-feat",
      "claude",
      File.join(project.root, "feat"),
      File.join(project.root, ".bare")
    ]
  end

  def setup_exec_argv
    ["sbx", "exec", "proj-feat", "--", "sh", "-c", "bundle install"]
  end

  def publish_argv(host_port)
    ["sbx", "ports", "proj-feat", "--publish", "#{host_port}:3000"]
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

  def script_template_preflight(fake, project)
    fake.script(%w[which sbx])
    fake.script(%w[which docker])
    script_git_identity(fake, project)
    fake.script(%w[sbx template ls], stdout: "img  1\n")
    fake.script(%w[sbx secret ls], stdout: "github\n")
  end

  def script_full_success(fake, project, host_port, listeners)
    script_template_preflight(fake, project)
    fake.script(inspect_argv, status: 1)
    fake.script(create_argv(project))
    fake.script(setup_exec_argv)
    fake.script(publish_argv(host_port))
    listen_after_publish(
      fake,
      host_port,
      listeners
    )
  end

  def expected_success_argvs(project, host_port)
    [
      *template_preflight_argvs(project),
      inspect_argv,
      create_argv(project),
      setup_exec_argv,
      publish_argv(host_port)
    ]
  end

  def expected_success_stdout(host_port)
    <<~TEXT
      Created sandbox: proj-feat
      Branch: feat
      Agent: claude
      Template: img:1
      Port: #{host_port}:3000
    TEXT
  end

  def expected_minimal_json
    payload = {
      "name" => "proj-feat",
      "branch" => "feat",
      "agent_type" => "claude"
    }
    "#{JSON.pretty_generate(payload)}\n"
  end

  def ports_file_path(project)
    File.join(
      project.root,
      ".orn",
      "sandbox",
      "proj-feat.ports"
    )
  end

  describe "#run" do
    before { stub_host_os("linux") }

    it "creates the sandbox, runs setup, publishes the configured port, and prints the result" do
      host_port = pick_free_port
      listeners = []
      project = sandbox_ready_project(full_config(host_port))
      approve_sbx_commands(project)
      with_fake_cmd do |fake|
        script_full_success(
          fake,
          project,
          host_port,
          listeners
        )

        expect { Dir.chdir(project.root) { command.run("feat") } }
          .to output(expected_success_stdout(host_port)).to_stdout
          .and output(/Creating sandbox 'proj-feat'/).to_stderr

        expect(fake.invocations).to eq(expected_success_argvs(project, host_port))
        expect(File).to exist(ports_file_path(project))
      end
    ensure
      listeners.each(&:close)
    end

    it "prints no template or port lines when neither is configured" do
      project = sandbox_ready_project(minimal_config)
      with_fake_cmd do |fake|
        script_passing_preflight(fake, project)
        fake.script(inspect_argv, status: 1)
        fake.script(minimal_create_argv(project))

        expect { Dir.chdir(project.root) { command.run("feat") } }
          .to output("Created sandbox: proj-feat\nBranch: feat\nAgent: claude\n").to_stdout
          .and output(/Creating sandbox 'proj-feat'/).to_stderr
      end
    end

    it "prints json that omits template and host_ports when neither is configured" do
      project = sandbox_ready_project(minimal_config)
      json_command = described_class.new(output_mode: Orn::OutputMode.quiet)
      with_fake_cmd do |fake|
        script_passing_preflight(fake, project)
        fake.script(inspect_argv, status: 1)
        fake.script(minimal_create_argv(project))

        expect { Dir.chdir(project.root) { json_command.run("feat") } }
          .to output(expected_minimal_json).to_stdout

        expect(fake.invocations).to eq(
          [
            *preflight_argvs(project),
            inspect_argv,
            minimal_create_argv(project)
          ]
        )
      end
    end
  end

  describe "#run_inner" do
    it "fails without an [sbx] section" do
      project = project_with("git:\n  base: main\n")

      expect { command.run_inner(project, "feature/x") }
        .to raise_error(Orn::Error, /No sbx section/)
    end

    it "fails without an agent_type" do
      project = project_with("sbx: {}\n")

      expect { command.run_inner(project, "feature/x") }
        .to raise_error(Orn::Error, /agent_type/)
    end

    it "fails when the worktree does not exist" do
      project = project_with("sbx:\n  agent_type: claude\n  template: my-image:latest\n")

      expect { command.run_inner(project, "feature/nonexistent") }
        .to raise_error(Orn::Error, /Worktree does not exist/)
    end

    it "suggests doctor when preflight fails" do
      project = project_with("sbx:\n  agent_type: claude\n  template: img:1\n")
      FileUtils.mkdir_p(File.join(project.root, "feature/x"))

      expect { command.run_inner(project, "feature/x") }
        .to raise_error(Orn::Error, /Preflight check failed.*orn sbx doctor/m)
    end

    it "fails when the sandbox already exists" do
      stub_host_os("linux")
      project = sandbox_ready_project(minimal_config)
      with_fake_cmd do |fake|
        script_passing_preflight(fake, project)
        fake.script(inspect_argv)

        expect { command.run_inner(project, "feat") }
          .to raise_error(Orn::Error, "Sandbox 'proj-feat' already exists")
      end
    end
  end

  describe "Result#to_json_hash" do
    it "includes template and host_ports when both are present" do
      result = described_class::Result.new(
        name: "proj-feat",
        branch: "feat",
        agent_type: "claude",
        template: "img:1",
        host_ports: [
          Orn::Sandbox::PortMapping.new(
            host: 40_000,
            container: 3000
          )
        ]
      )

      expect(result.to_json_hash).to eq(
        "name" => "proj-feat",
        "branch" => "feat",
        "agent_type" => "claude",
        "template" => "img:1",
        "host_ports" => [
          {
            "host" => 40_000,
            "container" => 3000
          }
        ]
      )
    end
  end

  describe "sandbox name derivation" do
    it "derives the sandbox name from the project directory and branch" do
      project = Orn::Git::Project.new(
        root: "/home/user/dev/my-project",
        config: Orn::Config.load("/nonexistent")
      )

      expect(project.sandbox_name("feature/x")).to eq("my-project-feature-x")
    end
  end
end
