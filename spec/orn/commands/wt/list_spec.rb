# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::List do
  def project_with_worktree(branch)
    remote = make_remote_with_branch(branch)
    project = make_bare_project
    add_origin(project, remote)
    worktree = Orn::Git::Worktree.new(
      root: project,
      output_mode: Orn::OutputMode.quiet
    )
    worktree.fetch("origin", branch)
    worktree.add(
      File.join(project, branch),
      branch,
      "origin/#{branch}"
    )
    project
  end

  describe "#run_inner" do
    it "returns the repo name and worktree branches" do
      project = project_with_worktree("feature/listed")

      result = Dir.chdir(project) { described_class.new(output_mode: Orn::OutputMode.quiet).run_inner }

      expect(result.repo).to eq(File.basename(File.realpath(project)))
      expect(result.worktrees).to include("feature/listed")
    end
  end

  describe "#run" do
    it "prints a table of worktrees for humans" do
      project = project_with_worktree("feature/listed")
      command = described_class.new(output_mode: Orn::OutputMode.default)

      expect { Dir.chdir(project) { command.run } }.to output(%r{feature/listed}).to_stdout
    end

    it "prints json in json mode" do
      project = project_with_worktree("feature/listed")
      command = described_class.new(output_mode: Orn::OutputMode.quiet)

      expect { Dir.chdir(project) { command.run } }.to output(%r{"feature/listed"}).to_stdout
    end
  end
end
