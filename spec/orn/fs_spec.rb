# frozen_string_literal: true

RSpec.describe Orn::Fs do
  describe ".prune_branch_dirs" do
    it "removes the branch's empty prefix directories, deepest first" do
      project = make_bare_project
      FileUtils.mkdir_p(File.join(project, "feature/deep"))

      described_class.prune_branch_dirs(project, "feature/deep/old")

      expect(File.exist?(File.join(project, "feature/deep"))).to be(false)
      expect(File.exist?(File.join(project, "feature"))).to be(false)
    end

    it "does nothing for a branch without prefix directories" do
      project = make_bare_project

      expect { described_class.prune_branch_dirs(project, "main") }.not_to raise_error
    end

    it "keeps prefixes still holding another worktree" do
      project = make_bare_project
      FileUtils.mkdir_p(File.join(project, "feature/keep"))

      described_class.prune_branch_dirs(project, "feature/old")

      expect(File.directory?(File.join(project, "feature/keep"))).to be(true)
    end

    it "does not follow a symlinked prefix" do
      project = make_bare_project
      target = File.join(project, "main")
      FileUtils.mkdir_p(File.join(target, "shared"))
      File.symlink(target, File.join(project, "feature"))

      expect { described_class.prune_branch_dirs(project, "feature/old") }.not_to raise_error

      expect(File.directory?(File.join(target, "shared"))).to be(true)
      expect(File.symlink?(File.join(project, "feature"))).to be(true)
    end

    it "swallows removal failures" do
      project = make_bare_project
      branch_dir = File.join(project, "feature")
      FileUtils.mkdir_p(File.join(branch_dir, "old"))
      # Read-only parent: rmdir of the empty child fails; the failure must
      # be swallowed.
      FileUtils.chmod(0o555, branch_dir)

      expect { described_class.prune_branch_dirs(project, "feature/old/x") }.not_to raise_error

      expect(File.directory?(File.join(branch_dir, "old"))).to be(true)
    ensure
      FileUtils.chmod(0o755, branch_dir) if branch_dir
    end
  end

  describe ".xdg_dir" do
    context "when the variable is set" do
      it "returns its value" do
        ENV["XDG_DATA_HOME"] = "/custom/data"

        expect(described_class.xdg_dir("XDG_DATA_HOME", ".local/share")).to eq("/custom/data")
      end
    end

    context "when the variable is empty" do
      it "falls back to a path under the home directory" do
        ENV["XDG_DATA_HOME"] = ""
        ENV["HOME"] = "/home/tester"

        expect(described_class.xdg_dir("XDG_DATA_HOME", ".local/share")).to eq("/home/tester/.local/share")
      end
    end

    context "when neither the variable nor HOME is set" do
      it "returns nil" do
        ENV.delete("XDG_DATA_HOME")
        ENV.delete("HOME")

        expect(described_class.xdg_dir("XDG_DATA_HOME", ".local/share")).to be_nil
      end
    end
  end
end
