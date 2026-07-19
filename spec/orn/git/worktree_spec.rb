# frozen_string_literal: true

RSpec.describe Orn::Git::Worktree do
  def worktree_for(root)
    described_class.new(
      root: root,
      output_mode: Orn::OutputMode.default
    )
  end

  describe "#local_branch_exists?" do
    context "when the branch is missing" do
      it "returns false" do
        worktree = worktree_for(make_bare_project)

        expect(worktree.local_branch_exists?("feature/nonexistent")).to be(false)
      end
    end

    context "when the branch exists" do
      it "returns true" do
        remote = make_remote_with_branch("feature/local-check")
        project = make_bare_project
        add_origin(project, remote)
        worktree = worktree_for(project)
        worktree.fetch("origin", "feature/local-check")
        worktree.add(
          File.join(project, "feature/local-check"),
          "feature/local-check",
          "origin/feature/local-check"
        )

        expect(worktree.local_branch_exists?("feature/local-check")).to be(true)
      end
    end

    context "when git itself fails to run" do
      it "returns false instead of raising" do
        with_fake_cmd do |fake|
          fake.script_missing(["git", "-C", "/project", "rev-parse", "--verify", "refs/heads/feature/x"])

          expect(worktree_for("/project").local_branch_exists?("feature/x")).to be(false)
        end
      end
    end
  end

  describe "#remote_branch_exists?" do
    context "when the remote branch exists" do
      it "returns true" do
        remote = make_remote_with_branch("feature/test-branch")
        project = make_bare_project
        add_origin(project, remote)

        expect(worktree_for(project).remote_branch_exists?("origin", "feature/test-branch")).to be(true)
      end
    end

    context "when the remote branch is missing" do
      it "returns false" do
        remote = make_remote_with_branch("feature/test-branch")
        project = make_bare_project
        add_origin(project, remote)

        expect(worktree_for(project).remote_branch_exists?("origin", "feature/nonexistent")).to be(false)
      end
    end

    context "when there is no remote" do
      it "returns false" do
        expect(worktree_for(make_bare_project).remote_branch_exists?("origin", "feature/anything")).to be(false)
      end
    end

    context "when git itself fails to run" do
      it "returns false instead of raising" do
        with_fake_cmd do |fake|
          fake.script_missing(["git", "-C", "/project", "ls-remote", "--heads", "origin", "feature/x"])

          expect(worktree_for("/project").remote_branch_exists?("origin", "feature/x")).to be(false)
        end
      end
    end
  end

  describe "#add" do
    context "with a fetched remote branch" do
      it "creates the worktree" do
        remote = make_remote_with_branch("feature/from-remote")
        project = make_bare_project
        add_origin(project, remote)
        worktree = worktree_for(project)
        worktree.fetch("origin", "feature/from-remote")

        path = File.join(project, "feature/from-remote")
        worktree.add(
          path,
          "feature/from-remote",
          "origin/feature/from-remote"
        )

        expect(File.exist?(path)).to be(true)
        expect(File.exist?(File.join(path, "g.txt"))).to be(true)
      end
    end

    context "when every strategy fails" do
      it "raises an error naming each failed attempt" do
        project = make_bare_project
        worktree = worktree_for(project)
        path = File.join(project, "no-such-branch")

        expect do
          worktree.add(
            path,
            "no-such-branch",
            "origin/main"
          )
        end
          .to raise_error(Orn::Error, /Attempt 1:.+Attempt 2:.+Attempt 3:/m)
      end
    end

    context "when every attempt fails with empty stderr" do
      let(:root) { "/project" }

      let(:branch) { "feature/x" }

      let(:path) { "/project/feature/x" }

      def attempt_argvs
        [
          ["git", "-C", root, "worktree", "add", "-b", branch, path, "origin/main"],
          ["git", "-C", root, "worktree", "add", "-b", branch, path, "main"],
          ["git", "-C", root, "worktree", "add", path, branch]
        ]
      end

      it "raises the base failure message without attempt lines" do
        with_fake_cmd do |fake|
          attempt_argvs.each { |argv| fake.script(argv, status: 1) }

          expect do
            worktree_for(root).add(
              path,
              branch,
              "origin/main"
            )
          end
            .to raise_error(Orn::Error, "Failed to create worktree for 'feature/x'")
        end
      end
    end
  end

  describe "#entries" do
    it "lists the branches of added worktrees, sorted" do
      remote = make_remote_with_branch("feature/listed")
      project = make_bare_project
      add_origin(project, remote)
      worktree = worktree_for(project)
      worktree.fetch("origin", "feature/listed")
      worktree.add(
        File.join(project, "feature/listed"),
        "feature/listed",
        "origin/feature/listed"
      )

      expect(worktree.entries).to include("feature/listed")
    end
  end
end
