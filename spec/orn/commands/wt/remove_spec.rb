# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::Remove, :real_cmd do
  subject(:command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

  def project_on(base = "main")
    # Realpath so scripted argvs match the root Project.discover resolves
    # (macOS realpaths /var temp dirs to /private/var).
    make_project(File.realpath(make_bare_project), "git:\n  base: #{base}\n")
  end

  def add_worktree(project, branch, remote)
    add_origin(project.root, remote)
    worktree = Orn::Git::Worktree.new(
      root: project.root,
      output_mode: Orn::OutputMode.quiet
    )
    worktree.fetch("origin", branch)
    worktree.add(
      project.worktree_path(branch),
      branch,
      "origin/#{branch}"
    )
    worktree
  end

  describe "#run" do
    def run_from(project, run_command, branches, prune:, force:)
      Dir.chdir(project.root) do
        run_command.run(
          branches,
          prune: prune,
          force: force
        )
      end
    end

    it "prompts for each branch before pruning interactively" do
      project = project_on
      interactive_command = described_class.new(output_mode: Orn::OutputMode.default)
      allow(Orn::Confirm).to receive(:prune_interactive)

      expect do
        run_from(
          project,
          interactive_command,
          %w[feature/a feature/b],
          prune: true,
          force: false
        )
      end.to output("No worktree found for feature/a\nNo worktree found for feature/b\n").to_stdout

      expect(Orn::Confirm).to have_received(:prune_interactive).with(project.root, "feature/a")
      expect(Orn::Confirm).to have_received(:prune_interactive).with(project.root, "feature/b")
    end

    it "skips the prompt when removal is forced" do
      project = project_on
      interactive_command = described_class.new(output_mode: Orn::OutputMode.default)
      allow(Orn::Confirm).to receive(:prune_interactive)

      expect do
        run_from(
          project,
          interactive_command,
          %w[feature/a],
          prune: true,
          force: true
        )
      end.to output("No worktree found for feature/a\n").to_stdout

      expect(Orn::Confirm).not_to have_received(:prune_interactive)
    end

    it "skips the prompt in json mode and prints the results as JSON" do
      project = project_on
      allow(Orn::Confirm).to receive(:prune_interactive)
      expected_payload = [
        {
          "branch" => "feature/a",
          "worktree_removed" => false,
          "branch_deleted" => false,
          "remote_branch_deleted" => false
        }
      ]

      expect do
        run_from(
          project,
          command,
          %w[feature/a],
          prune: true,
          force: false
        )
      end.to output("#{JSON.pretty_generate(expected_payload)}\n").to_stdout

      expect(Orn::Confirm).not_to have_received(:prune_interactive)
    end
  end

  describe "#run_inner" do
    context "when the branch is the base branch" do
      it "refuses to prune it" do
        %w[main develop].each do |base|
          project = project_on(base)

          expect do
            command.run_inner(
              project,
              base,
              true
            )
          end
            .to raise_error(Orn::Error, /Cannot prune the base branch/)
        end
      end

      it "allows removal without prune (no-op when no worktree)" do
        result = command.run_inner(
          project_on("main"),
          "main",
          false
        )

        expect(result.worktree_removed).to be(false)
        expect(result.branch_deleted).to be(false)
      end
    end

    context "when run from inside the worktree being removed" do
      it "refuses with a hint to cd out" do
        project = project_on
        allow(Dir).to receive(:pwd).and_return(project.worktree_path("feature/inside"))

        expect do
          command.run_inner(
            project,
            "feature/inside",
            false
          )
        end
          .to raise_error(Orn::Error, %r{Cannot remove worktree for 'feature/inside' while inside it})
      end
    end

    context "when the current directory cannot be determined" do
      it "proceeds with the removal" do
        project = project_on
        allow(Dir).to receive(:pwd).and_raise(Errno::ENOENT)

        result = command.run_inner(
          project,
          "feature/nowhere",
          false
        )

        expect(result.worktree_removed).to be(false)
      end
    end

    context "with --prune" do
      it "warns with git's stderr when a deletion fails" do
        project = project_on
        human_command = described_class.new(output_mode: Orn::OutputMode.default)

        with_fake_cmd do |fake|
          fake.script(
            ["git", "-C", project.root, "branch", "-D", "feature/x"],
            stderr: "error: branch 'feature/x' not found",
            status: 1
          )
          fake.script(
            ["git", "-C", project.root, "push", "origin", "--delete", "feature/x"],
            stderr: "fatal: could not read from remote repository",
            status: 1
          )

          result = nil
          expect do
            result = human_command.run_inner(
              project,
              "feature/x",
              true
            )
          end.to output(
            %r{could not delete local branch 'feature/x': error.*could not delete remote branch 'feature/x': fatal}m
          ).to_stderr

          aggregate_failures do
            expect(result.branch_deleted).to be(false)
            expect(result.remote_branch_deleted).to be(false)
          end
        end
      end

      it "removes the worktree and deletes the local and remote branch" do
        project = project_on
        add_worktree(
          project,
          "feature/both",
          make_remote_with_branch("feature/both")
        )

        result = command.run_inner(
          project,
          "feature/both",
          true
        )

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
      worktree = Orn::Git::Worktree.new(
        root: project.root,
        output_mode: Orn::OutputMode.quiet
      )
      %w[feature/multi-a feature/multi-b].each do |branch|
        worktree.fetch("origin", branch)
        worktree.add(
          project.worktree_path(branch),
          branch,
          "origin/#{branch}"
        )
      end

      results, errors = command.remove_multiple(
        project,
        %w[feature/multi-a feature/multi-b],
        false
      )

      expect(results.length).to eq(2)
      expect(errors).to be_empty
      expect(results.map(&:worktree_removed)).to all(be(true))
    end

    it "reports one branch's failure but still removes the others" do
      project = project_on("main")
      add_worktree(
        project,
        "feature/survive",
        make_remote_with_branch("feature/survive")
      )

      results, errors = command.remove_multiple(
        project,
        %w[main feature/survive],
        true
      )

      expect(results.length).to eq(1)
      expect(results.first.worktree_removed).to be(true)
      expect(errors.length).to eq(1)
      expect(errors.first).to include("main")
    end
  end

  describe "Result#print_summary" do
    it "prints a line for the worktree and each deleted branch" do
      result = described_class::Result.new(
        branch: "feature/x",
        worktree_removed: true,
        branch_deleted: true,
        remote_branch_deleted: true
      )

      expect { result.print_summary }.to output(<<~OUTPUT).to_stdout
        Removed worktree: feature/x
        Deleted branch: feature/x
        Deleted remote branch: feature/x
      OUTPUT
    end

    it "prints only the missing-worktree line when nothing was removed" do
      result = described_class::Result.new(
        branch: "feature/x",
        worktree_removed: false,
        branch_deleted: false,
        remote_branch_deleted: false
      )

      expect { result.print_summary }.to output("No worktree found for feature/x\n").to_stdout
    end
  end
end
