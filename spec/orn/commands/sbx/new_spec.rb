# frozen_string_literal: true

require "fileutils"

RSpec.describe Orn::Commands::Sbx::New do
  let(:mode) { Orn::OutputMode.default }

  def project_with(config)
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx")), config)
  end

  describe ".run_inner" do
    it "fails without an [sbx] section" do
      project = project_with("git:\n  base: main\n")

      expect { described_class.run_inner(mode, project, "feature/x") }
        .to raise_error(Orn::Error, /\[sbx\]/)
    end

    it "fails without an agent_type" do
      project = project_with("sbx: {}\n")

      expect { described_class.run_inner(mode, project, "feature/x") }
        .to raise_error(Orn::Error, /agent_type/)
    end

    it "fails when the worktree does not exist" do
      project = project_with("sbx:\n  agent_type: claude\n  template: my-image:latest\n")

      expect { described_class.run_inner(mode, project, "feature/nonexistent") }
        .to raise_error(Orn::Error, /Worktree does not exist/)
    end

    it "suggests doctor when preflight fails" do
      project = project_with("sbx:\n  agent_type: claude\n  template: img:1\n")
      FileUtils.mkdir_p(File.join(project.root, "feature/x"))

      expect { described_class.run_inner(mode, project, "feature/x") }
        .to raise_error(Orn::Error, /Preflight check failed.*orn sbx doctor/m)
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
