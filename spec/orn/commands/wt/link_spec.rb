# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::Link do
  subject(:command) { described_class.new(output_mode: Orn::OutputMode.default) }

  def project_with_base_env
    project = make_project(make_bare_project, "git:\n  base: main\nsymlinks:\n  base:\n    - \".env\"\n")
    base_wt = File.join(project.root, "main")
    FileUtils.mkdir_p(base_wt)
    File.write(File.join(base_wt, ".env"), "SECRET=x")
    project
  end

  describe "#run_inner" do
    it "creates the configured symlinks in the current worktree" do
      project = project_with_base_env
      target = File.join(project.root, "feature-x")
      FileUtils.mkdir_p(target)

      result = Dir.chdir(target) { command.run_inner }

      expect(result.created).to eq([".env"])
      expect(File.symlink?(File.join(target, ".env"))).to be(true)
    end
  end

  describe "#run" do
    it "reports when there are no symlinks configured" do
      project = make_project(make_bare_project, "git:\n  base: main\n")
      target = File.join(project.root, "feature-x")
      FileUtils.mkdir_p(target)

      expect { Dir.chdir(target) { command.run } }.to output("No symlinks to create\n").to_stdout
    end

    it "lists created symlinks for humans" do
      project = project_with_base_env
      target = File.join(project.root, "feature-y")
      FileUtils.mkdir_p(target)

      expect { Dir.chdir(target) { command.run } }.to output(/created: \.env/).to_stdout
    end
  end
end
