# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::Commands::Switch do
  let(:command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

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
        host_ports: [Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        )]
      )

      json = result.to_json_hash

      aggregate_failures do
        expect(json["sandbox_name"]).to eq("proj-feature-x")
        expect(json["host_ports"]).to eq(
          [{
            "host" => 3042,
            "container" => 3000
          }]
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

  describe "#perform with --sbx" do
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

  context "with a real tmux server", if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    it "creates the worktree and its tmux window for a brand-new branch" do
      root = standard_project("feature/other")
      project = load_project(root)

      result = command.perform(
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
          Orn::Tmux.window_exists?(
            Orn::OutputMode.quiet,
            session,
            "feature/fresh"
          )
        ).to be(true)
      end
    end

    it "just selects the window when it already exists" do
      root = standard_project("feature/other")
      project = load_project(root)
      command.perform(
        project,
        "feature/fresh",
        nil,
        false
      )

      result = command.perform(
        project,
        "feature/fresh",
        nil,
        false
      )

      expect(result.action).to eq(:switched)
    end
  end
end
