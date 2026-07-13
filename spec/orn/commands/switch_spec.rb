# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::Commands::Switch do
  def standard_project(seed_branch)
    remote = make_remote_with_branch(seed_branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(File.join(project, ".orn", "config.yaml"), "git:\n  base: main\n")
    project
  end

  def load_project(root)
    Orn::Git::Project.new(root: root, config: Orn::Config.load_from(root, nil))
  end

  describe "result JSON shape" do
    it "omits the optional fields for a plain switch" do
      json = described_class::Result.simple("feature/x", :switched).to_json_hash

      aggregate_failures do
        expect(json).to eq("branch" => "feature/x", "action" => "switched")
        expect(json).not_to have_key("base")
        expect(json).not_to have_key("worktree_path")
      end
    end

    it "includes base and path for a created branch" do
      result = described_class::Result.new(
        branch: "feature/x", action: :created, base: "main",
        worktree_path: "/path", sandbox_name: nil, host_ports: []
      )

      expect(result.to_json_hash).to include("base" => "main", "worktree_path" => "/path", "action" => "created")
    end
  end

  describe ".perform" do
    it "rejects --sbx until sandbox support lands" do
      root = standard_project("feature/other")

      expect { described_class.perform(Orn::OutputMode.quiet, load_project(root), "feature/new", nil, true) }
        .to raise_error(Orn::Error, /sandbox creation is not yet supported/)
    end
  end

  context "with a real tmux server", if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    it "creates the worktree and its tmux window for a brand-new branch" do
      root = standard_project("feature/other")
      project = load_project(root)

      result = described_class.perform(Orn::OutputMode.quiet, project, "feature/fresh", nil, false)
      session = Orn::Session.session_name(project)

      aggregate_failures do
        expect(result.action).to eq(:created)
        expect(File).to be_directory(File.join(root, "feature/fresh"))
        expect(Orn::Tmux.window_exists?(Orn::OutputMode.quiet, session, "feature/fresh")).to be(true)
      end
    end

    it "just selects the window when it already exists" do
      root = standard_project("feature/other")
      project = load_project(root)
      described_class.perform(Orn::OutputMode.quiet, project, "feature/fresh", nil, false)

      result = described_class.perform(Orn::OutputMode.quiet, project, "feature/fresh", nil, false)

      expect(result.action).to eq(:switched)
    end
  end
end
