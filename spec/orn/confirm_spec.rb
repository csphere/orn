# frozen_string_literal: true

require "stringio"

RSpec.describe Orn::Confirm do
  def capture(input)
    writer = StringIO.new
    result = yield(StringIO.new(input), writer)
    [result, writer.string]
  end

  describe ".prune" do
    def prune(branch, has_local, has_remote, input)
      capture(input) do |reader, writer|
        described_class.prune(
          branch,
          has_local,
          has_remote,
          reader,
          writer
        )
      end
    end

    context "when answered" do
      it "confirms on y/yes (case-insensitively)" do
        expect(
          prune(
            "b",
            true,
            true,
            "y\n"
          ).first
        ).to be(true)
        expect(
          prune(
            "b",
            true,
            true,
            "yes\n"
          ).first
        ).to be(true)
        expect(
          prune(
            "b",
            true,
            true,
            "Y\n"
          ).first
        ).to be(true)
        expect(
          prune(
            "b",
            true,
            true,
            "YES\n"
          ).first
        ).to be(true)
      end

      it "denies on n, blank input, and EOF" do
        expect(
          prune(
            "b",
            true,
            true,
            "n\n"
          ).first
        ).to be(false)
        expect(
          prune(
            "b",
            true,
            true,
            "\n"
          ).first
        ).to be(false)
        expect(
          prune(
            "b",
            true,
            true,
            ""
          ).first
        ).to be(false)
      end
    end

    context "when summarizing what will be deleted" do
      it "lists only the local branch when only it exists" do
        _, output = prune(
          "feature/test",
          true,
          false,
          "n\n"
        )

        expect(output).to include("Local branch: feature/test")
        expect(output).not_to include("Remote branch")
      end

      it "lists only the remote branch when only it exists" do
        _, output = prune(
          "feature/test",
          false,
          true,
          "n\n"
        )

        expect(output).not_to include("Local branch")
        expect(output).to include("Remote branch: origin/feature/test")
      end

      it "lists both branches and the continue prompt" do
        _, output = prune(
          "feature/test",
          true,
          true,
          "n\n"
        )

        expect(output).to include("Local branch: feature/test")
        expect(output).to include("Remote branch: origin/feature/test")
        expect(output).to include("Continue? [y/N]")
      end
    end
  end

  describe ".global_config" do
    def global_config(path, input)
      capture(input) do |reader, writer|
        described_class.global_config(
          path,
          reader,
          writer
        )
      end
    end

    it "confirms on yes and denies on no/EOF" do
      expect(global_config("/tmp/orn/default.yaml", "yes\n").first).to be(true)
      expect(global_config("/tmp/orn/default.yaml", "n\n").first).to be(false)
      expect(global_config("/tmp/orn/default.yaml", "").first).to be(false)
    end

    it "shows the path, the not-found message, and the create prompt" do
      _, output = global_config("/tmp/orn/default.yaml", "n\n")

      expect(output).to include("/tmp/orn/default.yaml")
      expect(output).to include("Global config not found")
      expect(output).to include("Create it? [y/N]")
    end
  end

  describe ".gitignore" do
    def gitignore(paths, input)
      capture(input) do |reader, writer|
        described_class.gitignore(
          paths,
          reader,
          writer
        )
      end
    end

    it "confirms on y and denies on n/blank" do
      expect(gitignore(["shared_docs"], "y\n").first).to be(true)
      expect(gitignore(["shared_docs"], "n\n").first).to be(false)
      expect(gitignore(["shared_docs"], "\n").first).to be(false)
    end

    it "lists each missing path, the options, and the prompt" do
      _, output = gitignore(%w[shared_docs other_link], "n\n")

      expect(output).to include("'shared_docs'")
      expect(output).to include("'other_link'")
      expect(output).to include("y: add to .gitignore")
      expect(output).to include("n: cancel and remove the worktree")
      expect(output).to include("Proceed? [y/n]")
    end
  end
end
