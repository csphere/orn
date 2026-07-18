# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::New do
  def standard_project(branch = "feature/existing")
    remote = make_remote_with_branch(branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(File.join(project, ".orn", "config.yaml"), "git:\n  base: main\n")
    project
  end

  def load_project(root)
    Orn::Git::Project.new(root: root, config: Orn::Config.load_from(root, nil))
  end

  describe ".create" do
    it "creates a worktree tracking the remote branch when it exists" do
      root = standard_project("feature/existing")

      result = described_class.create(Orn::OutputMode.quiet, load_project(root), "feature/existing", nil)

      aggregate_failures do
        expect(result.from_remote).to be(true)
        expect(result.branch).to eq("feature/existing")
        expect(File).to exist(File.join(root, "feature/existing", "g.txt"))
      end
    end

    it "creates a worktree off base when the branch is new" do
      root = standard_project("feature/other")

      result = described_class.create(Orn::OutputMode.quiet, load_project(root), "feature/brand-new", nil)

      aggregate_failures do
        expect(result.from_remote).to be(false)
        expect(result.base).to eq("main")
        expect(File).to be_directory(File.join(root, "feature/brand-new"))
      end
    end

    it "raises when the worktree already exists" do
      root = standard_project("feature/existing")
      FileUtils.mkdir_p(File.join(root, "feature/existing"))

      expect { described_class.create(Orn::OutputMode.quiet, load_project(root), "feature/existing", nil) }
        .to raise_error(Orn::Error, /already exists/)
    end
  end
end
