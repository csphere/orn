# frozen_string_literal: true

RSpec.describe Orn::Git::Project do
  describe ".discover_root_from" do
    context "with a relative gitdir pointer" do
      it "resolves the project root" do
        project = make_bare_project

        expect(described_class.discover_root_from(project)).to eq(File.realpath(project))
      end
    end

    context "with an absolute gitdir pointer" do
      it "resolves the project root" do
        project = make_bare_project
        bare_absolute = File.realpath(File.join(project, ".bare"))
        File.write(File.join(project, ".git"), "gitdir: #{bare_absolute}\n")

        expect(described_class.discover_root_from(project)).to eq(File.realpath(project))
      end
    end

    context "when inside a worktree" do
      it "resolves the project root" do
        project = make_bare_project
        worktree_dir = File.join(project, "feature/my-branch")
        FileUtils.mkdir_p(worktree_dir)
        FileUtils.mkdir_p(File.join(project, ".bare/worktrees/my-branch"))
        File.write(
          File.join(worktree_dir, ".git"),
          "gitdir: #{project}/.bare/worktrees/my-branch\n"
        )

        expect(described_class.discover_root_from(worktree_dir)).to eq(File.realpath(project))
      end
    end

    context "when in a deep subdirectory of a worktree" do
      it "walks up and resolves the project root" do
        project = make_bare_project
        worktree_dir = File.join(project, "feature/my-branch")
        FileUtils.mkdir_p(worktree_dir)
        FileUtils.mkdir_p(File.join(project, ".bare/worktrees/my-branch"))
        File.write(
          File.join(worktree_dir, ".git"),
          "gitdir: #{project}/.bare/worktrees/my-branch\n"
        )
        deep = File.join(worktree_dir, "src/components/nested")
        FileUtils.mkdir_p(deep)

        expect(described_class.discover_root_from(deep)).to eq(File.realpath(project))
      end
    end

    context "when the .git file is a symlink" do
      it "follows it and resolves the project root" do
        project = make_bare_project
        real_git = File.join(project, ".git-real")
        FileUtils.mv(File.join(project, ".git"), real_git)
        File.symlink(real_git, File.join(project, ".git"))

        expect(described_class.discover_root_from(project)).to eq(File.realpath(project))
      end
    end

    context "with a .git directory instead of a pointer file" do
      it "rejects it as not a bare-worktree project" do
        dir = Dir.mktmpdir("orn-plain")
        register_temp_dir(dir)
        FileUtils.mkdir_p(File.join(dir, ".git"))

        expect { described_class.discover_root_from(dir) }
          .to raise_error(Orn::Error, /not a bare worktree project/)
      end
    end

    context "when outside any git repository" do
      it "reports that it is not inside a git repository" do
        dir = register_temp_dir(Dir.mktmpdir("orn-outside"))

        expect { described_class.discover_root_from(dir) }
          .to raise_error(Orn::Error, /Not inside a git repository/)
      end
    end

    context "with an unrecognized pointer" do
      it "reports that the project root could not be determined" do
        dir = register_temp_dir(Dir.mktmpdir("orn-bad-pointer"))
        File.write(File.join(dir, ".git"), "not a valid pointer\n")

        expect { described_class.discover_root_from(dir) }
          .to raise_error(Orn::Error, /Could not determine orn project root/)
      end
    end

    context "with a pointer to a nonexistent path" do
      it "reports that the pointer could not be resolved" do
        dir = register_temp_dir(Dir.mktmpdir("orn-dangling"))
        File.write(File.join(dir, ".git"), "gitdir: ./nonexistent/.bare\n")

        expect { described_class.discover_root_from(dir) }
          .to raise_error(Orn::Error, /Failed to resolve .git pointer/)
      end
    end

    context "with a pointer to a directory outside any orn layout" do
      it "reports that the project root could not be determined" do
        dir = register_temp_dir(Dir.mktmpdir("orn-stray-pointer"))
        FileUtils.mkdir_p(File.join(dir, "plain"))
        File.write(File.join(dir, ".git"), "gitdir: ./plain\n")

        expect { described_class.discover_root_from(dir) }
          .to raise_error(Orn::Error, /Could not determine orn project root/)
      end
    end

    context "when the .git file cannot be read" do
      it "reports the read failure" do
        skip "chmod cannot revoke read access from root" if Process.uid.zero?

        dir = register_temp_dir(Dir.mktmpdir("orn-unreadable"))
        git_path = File.join(dir, ".git")
        File.write(git_path, "gitdir: ./.bare\n")
        File.chmod(0o000, git_path)

        expect { described_class.discover_root_from(dir) }
          .to raise_error(Orn::Error, /Failed to read .git file/)
      end
    end
  end

  describe ".discover_root" do
    context "when the resolved root has no .bare directory" do
      # Every pointer layout discover_root_from accepts resolves next to an
      # existing .bare directory, so this state cannot be built on disk; the
      # resolution step is stubbed to return a bare-less root instead.
      it "explains how to set up a project" do
        dir = register_temp_dir(Dir.mktmpdir("orn-no-bare"))
        allow(described_class).to receive(:discover_root_from).and_return(dir)

        expect { described_class.discover_root }
          .to raise_error(Orn::Error, /Not an orn project \(no \.bare directory found\)/)
      end
    end
  end

  def project_at(root)
    described_class.new(
      root: root,
      config: Orn::Config.load_from("/nonexistent", nil)
    )
  end

  describe "#worktree_path" do
    it "is a direct child of the project root" do
      project = project_at("/home/user/dev/my-project")

      expect(project.worktree_path("feature/ABC-1234")).to eq("/home/user/dev/my-project/feature/ABC-1234")
    end
  end

  describe "#sandbox_name" do
    it "combines the session (directory) name and the branch" do
      expect(project_at("/home/user/dev/my-project").sandbox_name("main")).to eq("my-project-main")
    end

    it "sanitizes slashes in the branch" do
      project = project_at("/home/user/dev/my-project")

      expect(project.sandbox_name("feature/ABC-123")).to eq("my-project-feature-ABC-123")
    end

    it "sanitizes other special characters" do
      expect(project_at("/home/user/dev/my-project").sandbox_name("issues/21")).to eq("my-project-issues-21")
    end

    it "uses the configured session name" do
      project = make_project(make_bare_project, "tmux:\n  session: custom\n")

      expect(project.sandbox_name("feature/x")).to eq("custom-feature-x")
    end
  end
end
