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

  describe "#run_inner_with_remote" do
    context "when the branch is the base branch" do
      it "refuses to prune it" do
        %w[main develop].each do |base|
          project = project_on(base)

          expect { command.run_inner_with_remote(project, base, true, true) }
            .to raise_error(Orn::Error, /Cannot prune the base branch/)
        end
      end

      it "allows removal without prune (no-op when no worktree)" do
        result = command.run_inner_with_remote(project_on("main"), "main", false, false)

        expect(result.worktree_removed).to be(false)
        expect(result.branch_deleted).to be(false)
      end
    end

    context "with --prune" do
      it "removes the worktree and deletes the local and remote branch" do
        project = project_on
        add_worktree(project, "feature/both", make_remote_with_branch("feature/both"))

        result = command.run_inner_with_remote(project, "feature/both", true, true)

        expect(result.worktree_removed).to be(true)
        expect(result.branch_deleted).to be(true)
        expect(result.remote_branch_deleted).to be(true)
      end

      it "leaves the remote branch alone when prune_remote is false" do
        project = project_on
        worktree = add_worktree(project, "feature/local", make_remote_with_branch("feature/local"))

        result = command.run_inner_with_remote(project, "feature/local", true, false)

        expect(result.branch_deleted).to be(true)
        expect(result.remote_branch_deleted).to be(false)
        expect(worktree.remote_branch_exists?("origin", "feature/local")).to be(true)
      end
    end

    context "with a blackboard entry" do
      it "removes the entry along with the worktree" do
        project = project_on
        add_worktree(project, "issues/52", make_remote_with_branch("issues/52"))
        Orn::Blackboard.create_entry(project.root, "issues/52")

        command.run_inner_with_remote(project, "issues/52", false, false)

        expect(File.exist?(File.join(project.root, ".orn/blackboard/issues/52"))).to be(false)
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

      results, errors = command.remove_multiple(project, %w[feature/multi-a feature/multi-b], false, false)

      expect(results.length).to eq(2)
      expect(errors).to be_empty
      expect(results.map(&:worktree_removed)).to all(be(true))
    end

    it "reports one branch's failure but still removes the others" do
      project = project_on("main")
      add_worktree(project, "feature/survive", make_remote_with_branch("feature/survive"))

      results, errors = command.remove_multiple(project, %w[main feature/survive], true, true)

      expect(results.length).to eq(1)
      expect(results.first.worktree_removed).to be(true)
      expect(errors.length).to eq(1)
      expect(errors.first).to include("main")
    end
  end
end
