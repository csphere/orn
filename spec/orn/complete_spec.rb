# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::Complete, :real_cmd do
  def project_with_worktree(branch)
    remote = make_remote_with_branch(branch)
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

  describe ".branch_candidates" do
    it "lists the project's worktree branches" do
      project = project_with_worktree("feature/listed")

      branches = Dir.chdir(project) { described_class.branch_candidates }

      expect(branches).to include("feature/listed")
    end

    it "returns an empty list outside a project" do
      candidates = Dir.mktmpdir { |dir| Dir.chdir(dir) { described_class.branch_candidates } }

      expect(candidates).to eq([])
    end
  end

  describe ".print_candidates" do
    it "prints one branch per line" do
      project = project_with_worktree("feature/printed")

      expect { Dir.chdir(project) { described_class.print_candidates } }.to output(%r{feature/printed}).to_stdout
    end
  end
end
