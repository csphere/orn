# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::Open do
  def standard_project(branch)
    remote = make_remote_with_branch(branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(File.join(project, ".orn", "config.yaml"), "git:\n  base: main\n")
    project
  end

  def load_project(root)
    Orn::Git::Project.new(root: root, config: Orn::Config.load_from(root, nil))
  end

  describe ".resolve" do
    it "returns the existing worktree path without creating anything" do
      root = standard_project("feature/other")
      FileUtils.mkdir_p(File.join(root, "feature/local"))

      result = described_class.resolve(Orn::OutputMode.quiet, load_project(root), "feature/local")

      aggregate_failures do
        expect(result.created).to be(false)
        expect(result.path).to eq(File.join(root, "feature/local"))
      end
    end

    it "creates the worktree from the remote branch when it is not local" do
      root = standard_project("feature/remote-only")

      result = described_class.resolve(Orn::OutputMode.quiet, load_project(root), "feature/remote-only")

      aggregate_failures do
        expect(result.created).to be(true)
        expect(File).to exist(File.join(root, "feature/remote-only", "g.txt"))
      end
    end

    it "raises when the branch exists neither locally nor on the remote" do
      root = standard_project("feature/other")

      expect { described_class.resolve(Orn::OutputMode.quiet, load_project(root), "feature/missing") }
        .to raise_error(Orn::Error, /No worktree found for.*does not exist on the remote/m)
    end
  end
end
