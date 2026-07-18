# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::Remove do
  subject(:command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

  def project_on(base = "main")
    make_project(make_bare_project, "git:\n  base: #{base}\n")
  end

  def add_worktree(project, branch, remote)
    add_origin(project.root, remote)
    worktree = Orn::Git::Worktree.new(root: project.root, output_mode: Orn::OutputMode.quiet)
    worktree.fetch("origin", branch)
    worktree.add(project.worktree_path(branch), branch, "origin/#{branch}")
    worktree
  end

  describe "#run_inner" do
    context "when the branch is the base branch" do
      it "refuses to prune it" do
        %w[main develop].each do |base|
          project = project_on(base)

          expect { command.run_inner(project, base, true) }
            .to raise_error(Orn::Error, /Cannot prune the base branch/)
        end
      end

      it "allows removal without prune (no-op when no worktree)" do
        result = command.run_inner(project_on("main"), "main", false)

        expect(result.worktree_removed).to be(false)
        expect(result.branch_deleted).to be(false)
      end
    end

    context "with --prune" do
      it "removes the worktree and deletes the local and remote branch" do
        project = project_on
        add_worktree(project, "feature/both", make_remote_with_branch("feature/both"))

        result = command.run_inner(project, "feature/both", true)

        expect(result.worktree_removed).to be(true)
        expect(result.branch_deleted).to be(true)
        expect(result.remote_branch_deleted).to be(true)
      end
    end
  end

  describe "#remove_multiple" do
    it "removes every worktree in the batch" do
      project = project_on
      remote = make_remote_with_branch("feature/multi-a")
      add_origin(project.root, remote)
      push_branch(remote, "feature/multi-b")
      worktree = Orn::Git::Worktree.new(root: project.root, output_mode: Orn::OutputMode.quiet)
      %w[feature/multi-a feature/multi-b].each do |branch|
        worktree.fetch("origin", branch)
        worktree.add(project.worktree_path(branch), branch, "origin/#{branch}")
      end

      results, errors = command.remove_multiple(project, %w[feature/multi-a feature/multi-b], false)

      expect(results.length).to eq(2)
      expect(errors).to be_empty
      expect(results.map(&:worktree_removed)).to all(be(true))
    end

    it "reports one branch's failure but still removes the others" do
      project = project_on("main")
      add_worktree(project, "feature/survive", make_remote_with_branch("feature/survive"))

      results, errors = command.remove_multiple(project, %w[main feature/survive], true)

      expect(results.length).to eq(1)
      expect(results.first.worktree_removed).to be(true)
      expect(errors.length).to eq(1)
      expect(errors.first).to include("main")
    end
  end
end
