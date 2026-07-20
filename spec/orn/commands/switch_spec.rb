# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require "tmpdir"

RSpec.describe Orn::Commands::Switch do
  let(:client) { FakeTmuxClient.new }
  let(:command) do
    described_class.new(
      output_mode: Orn::OutputMode.quiet,
      client: client
    )
  end
  let(:human_command) do
    described_class.new(
      output_mode: Orn::OutputMode.default,
      client: client
    )
  end

  def standard_project(seed_branch)
    remote = make_remote_with_branch(seed_branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(
      File.join(
        project,
        ".orn",
        "config.yaml"
      ),
      "git:\n  base: main\n"
    )
    project
  end

  def load_project(root)
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  def sbx_project(seed_branch, config)
    remote = make_remote_with_branch(seed_branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(
      File.join(
        project,
        ".orn",
        "config.yaml"
      ),
      config
    )
    load_project(project)
  end

  describe "result JSON shape" do
    it "omits the optional fields for a plain switch" do
      json = described_class::Result.simple("feature/x", :switched).to_json_hash

      aggregate_failures do
        expect(json).to eq(
          "branch" => "feature/x",
          "action" => "switched"
        )
        expect(json).not_to have_key("base")
        expect(json).not_to have_key("worktree_path")
        expect(json).not_to have_key("sandbox_name")
        expect(json).not_to have_key("host_ports")
      end
    end

    it "includes base and path for a created branch" do
      result = described_class::Result.new(
        branch: "feature/x",
        action: :created,
        base: "main",
        worktree_path: "/path",
        sandbox_name: nil,
        host_ports: []
      )

      expect(result.to_json_hash).to include(
        "base" => "main",
        "worktree_path" => "/path",
        "action" => "created"
      )
    end

    it "includes the sandbox name and published ports for a created sandbox" do
      result = described_class::Result.new(
        branch: "feature/x",
        action: :created,
        base: "main",
        worktree_path: "/path",
        sandbox_name: "proj-feature-x",
        host_ports: [
          Orn::Sandbox::PortMapping.new(
            host: 3042,
            container: 3000
          )
        ]
      )

      json = result.to_json_hash

      aggregate_failures do
        expect(json["sandbox_name"]).to eq("proj-feature-x")
        expect(json["host_ports"]).to eq(
          [
            {
              "host" => 3042,
              "container" => 3000
            }
          ]
        )
      end
    end

    it "includes the sandbox name but omits empty ports for a reopened sandbox" do
      result = described_class::Result.new(
        branch: "feature/x",
        action: :reopened,
        base: nil,
        worktree_path: nil,
        sandbox_name: "proj-feature-x",
        host_ports: []
      )

      json = result.to_json_hash

      aggregate_failures do
        expect(json["sandbox_name"]).to eq("proj-feature-x")
        expect(json).not_to have_key("host_ports")
      end
    end
  end

  describe "#perform with --sbx", :real_cmd do
    it "fails when there is no [sbx] section" do
      project = sbx_project("feature/other", "git:\n  base: main\n")

      expect do
        command.perform(
          project,
          "feature/new",
          nil,
          true
        )
      end
        .to raise_error(Orn::Error, /No sbx section.*config\.yaml/m)
    end

    it "fails when [sbx] has no agent_type" do
      project = sbx_project("feature/other", "sbx: {}\n")

      expect do
        command.perform(
          project,
          "feature/new",
          nil,
          true
        )
      end
        .to raise_error(Orn::Error, /agent_type/)
    end

    it "does not require [sbx] config in plain mode" do
      project = make_project(register_temp_dir(Dir.mktmpdir("orn-switch")), "git:\n  base: main\n")

      expect do
        command.perform(
          project,
          "feature/new",
          nil,
          false
        )
      end
        .to raise_error(Orn::Error) { |error| expect(error.message).not_to include("sbx") }
    end
  end

  describe "#run" do
    # A bare project the command can rediscover from inside its root, with an
    # isolated global config and a private XDG data dir for trust approvals.
    def discoverable_project(config_yaml)
      root = File.realpath(make_bare_project)
      File.write(File.join(root, ".orn", "config.yaml"), config_yaml)
      isolate_global_config
      ENV["XDG_DATA_HOME"] = register_temp_dir(Dir.mktmpdir("orn-switch-data"))
      load_project(root)
    end

    def feat_path(project)
      project.worktree_path("feat")
    end

    def plain_switch_config
      <<~YAML
        tmux:
          session: proj
          columns: []
      YAML
    end

    def sbx_start_config
      <<~YAML
        tmux:
          session: proj
          columns: []
        sbx:
          agent_type: claude
          start: bin/serve
      YAML
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

    # --- Command lines ---

    def ls_remote_argv(root)
      ["git", "-C", root, "ls-remote", "--heads", "origin", "feat"]
    end

    def fetch_argv(root, ref)
      ["git", "-C", root, "fetch", "origin", ref]
    end

    def worktree_add_argv(root, start_point)
      ["git", "-C", root, "worktree", "add", "-b", "feat", File.join(root, "feat"), start_point]
    end

    def inspect_argv
      %w[sbx inspect proj-feat]
    end

    def publish_argv(host_port)
      ["sbx", "ports", "proj-feat", "--publish", "#{host_port}:3000"]
    end

    def start_exec_argv
      ["sbx", "exec", "-d", "proj-feat", "--", "sh", "-c", "bin/serve"]
    end

    it "rejects an invalid branch name before running any command" do
      with_fake_cmd do |fake|
        expect { human_command.run("feat..bad") }
          .to raise_error(Orn::Error, /Invalid branch name/)
        expect(fake.invocations).to be_empty
      end
    end

    it "rejects an invalid base override before running any command" do
      with_fake_cmd do |fake|
        expect { human_command.run("feat", base_override: "base..bad") }
          .to raise_error(Orn::Error, /Invalid branch name/)
        expect(fake.invocations).to be_empty
      end
    end

    it "checks the existing session for a collision before switching to the window" do
      project = discoverable_project("")
      session = File.basename(project.root)
      ENV.delete("TMUX")
      # The session path resolves to this project, so the collision check
      # decides the session is ours and switch proceeds without a prompt.
      client.sessions = [session]
      client.session_paths = { session => project.root }
      client.windows = { session => ["feat"] }

      expect { Dir.chdir(project.root) { human_command.run("feat") } }
        .to output("Switched to window: feat\n").to_stdout

      expect(client.calls).to eq(
        [
          [:session_exists?, session],
          [:session_path, session],
          [:window_exists?, session, "feat"],
          [:select_window, session, "feat"]
        ]
      )
    end

    it "prints the result as json in json mode" do
      project = discoverable_project(plain_switch_config)
      client.windows = { "proj" => ["feat"] }

      expected_json = <<~JSON
        {
          "branch": "feat",
          "action": "switched"
        }
      JSON

      expect { Dir.chdir(project.root) { command.run("feat") } }
        .to output(expected_json).to_stdout
    end

    it "fetches a remote-only branch, creates its worktree, and opens its window" do
      project = discoverable_project(plain_switch_config)
      with_fake_cmd do |fake|
        fake.script(ls_remote_argv(project.root), stdout: "abc123\trefs/heads/feat\n")
        fake.script(fetch_argv(project.root, "main"))
        fake.script(fetch_argv(project.root, "feat"))
        fake.script(worktree_add_argv(project.root, "origin/feat"))

        expect { Dir.chdir(project.root) { human_command.run("feat") } }
          .to output("Fetched from remote and opened: feat\n").to_stdout
          .and output(/Checking remote for feat/).to_stderr

        aggregate_failures do
          expect(fake.invocations).to eq(
            [
              ls_remote_argv(project.root),
              fetch_argv(project.root, "main"),
              ls_remote_argv(project.root),
              fetch_argv(project.root, "feat"),
              worktree_add_argv(project.root, "origin/feat")
            ]
          )
          expect(client.calls).to include(
            [:window_exists?, "proj", "feat"],
            [:open_window, "feat"]
          )
        end
      end
    end

    it "reopens the window for an existing worktree when its sandbox is gone" do
      project = discoverable_project(plain_switch_config)
      FileUtils.mkdir_p(feat_path(project))
      with_fake_cmd do |fake|
        fake.script(inspect_argv, status: 1)

        expect { Dir.chdir(project.root) { human_command.run("feat") } }
          .to output("Reopened window for feat\n").to_stdout
          .and output(/Reopening window for feat/).to_stderr

        aggregate_failures do
          expect(fake.invocations).to eq([inspect_argv])
          expect(client.calls).to include([:open_window, "feat"])
        end
      end
    end

    # A discoverable sbx project whose "feat" worktree already exists on disk
    # and whose sbx commands are pre-approved.
    def approved_sandbox_project
      project = discoverable_project(sbx_start_config)
      approve_sbx_commands(project)
      FileUtils.mkdir_p(feat_path(project))
      project
    end

    def script_sandbox_reopen(fake, host_port)
      fake.script(inspect_argv)
      fake.script(publish_argv(host_port))
      fake.script(start_exec_argv)
    end

    it "reopens through the sandbox path, republishing ports and restarting services" do
      project = approved_sandbox_project
      # A live listener stands in for the sandbox service, so the real
      # verify_port probe connects instead of timing out.
      listener = TCPServer.new("127.0.0.1", 0)
      host_port = listener.addr[1]
      write_ports_file(project.root, host_port)
      with_fake_cmd do |fake|
        script_sandbox_reopen(fake, host_port)

        expect { Dir.chdir(project.root) { human_command.run("feat") } }
          .to output("Reopened window for feat\nSandbox: proj-feat\nPort: #{host_port}:3000\n").to_stdout
          .and output(/Reopening window for feat/).to_stderr

        aggregate_failures do
          expect(fake.invocations).to eq(
            [
              inspect_argv,
              publish_argv(host_port),
              start_exec_argv
            ]
          )
          expect(client.calls).to include([:open_window_with_layout, "feat"])
        end
      end
    ensure
      listener&.close
    end

    it "creates a brand-new branch and prints the created fields" do
      project = discoverable_project(plain_switch_config)
      with_fake_cmd do |fake|
        fake.script(ls_remote_argv(project.root))
        fake.script(fetch_argv(project.root, "main"))
        fake.script(worktree_add_argv(project.root, "origin/main"))

        expect { Dir.chdir(project.root) { human_command.run("feat") } }
          .to output("Branch: feat\nBase: main\nPath: #{feat_path(project)}\n").to_stdout
          .and output(/Creating worktree/).to_stderr

        expect(client.calls).to include([:open_window, "feat"])
      end
    end
  end

  context "with a real tmux server", :real_cmd, if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    let(:real_command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

    it "creates the worktree and its tmux window for a brand-new branch" do
      root = standard_project("feature/other")
      project = load_project(root)

      result = real_command.perform(
        project,
        "feature/fresh",
        nil,
        false
      )
      session = Orn::Session.session_name(project)

      aggregate_failures do
        expect(result.action).to eq(:created)
        expect(File).to be_directory(File.join(root, "feature/fresh"))
        expect(
          Orn::Tmux::Client.new(output_mode: Orn::OutputMode.quiet)
            .window_exists?(session, "feature/fresh")
        ).to be(true)
      end
    end

    it "just selects the window when it already exists" do
      root = standard_project("feature/other")
      project = load_project(root)
      real_command.perform(
        project,
        "feature/fresh",
        nil,
        false
      )

      result = real_command.perform(
        project,
        "feature/fresh",
        nil,
        false
      )

      expect(result.action).to eq(:switched)
    end
  end
end
