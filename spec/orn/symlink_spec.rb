# frozen_string_literal: true

RSpec.describe Orn::Symlink do
  let(:mode) { Orn::OutputMode.default }

  def temp_dir(name)
    register_temp_dir(Dir.mktmpdir(name))
  end

  def symlinks(base: [], root: [])
    Orn::Config::SymlinksConfig.new(
      base: base,
      root: root
    )
  end

  def root_symlink(source:, dest: nil)
    Orn::Config::RootSymlink.new(
      source: source,
      dest: dest
    )
  end

  describe ".validate_entry!" do
    context "with a safe relative path" do
      it "accepts dotfiles, nested paths, and names containing dots" do
        expect { described_class.validate_entry!(".env") }.not_to raise_error
        expect { described_class.validate_entry!(".claude/settings.local.json") }.not_to raise_error
        expect { described_class.validate_entry!("foo..bar") }.not_to raise_error
      end
    end

    context "with a traversing path" do
      it "rejects '..' components, whether leading, mid-path, or trailing" do
        ["..", "../../.ssh/id_rsa", "foo/../../bar", "foo/.."].each do |entry|
          expect { described_class.validate_entry!(entry) }.to raise_error(Orn::Error, /traversal/)
        end
      end

      it "rejects absolute paths" do
        expect { described_class.validate_entry!("/etc/passwd") }.to raise_error(Orn::Error, /absolute/)
      end
    end
  end

  describe ".create_symlinks" do
    context "with a traversing or absolute entry" do
      it "rejects a base entry that traverses" do
        root = temp_dir("root")
        FileUtils.mkdir_p(File.join(root, "develop"))
        config = symlinks(base: ["../../../.ssh/id_rsa"])

        expect do
          described_class.create_symlinks(
            root,
            temp_dir("wt"),
            "develop",
            config
          )
        end
          .to raise_error(Orn::Error, /traversal/)
      end

      it "rejects a root source that traverses" do
        config = symlinks(root: [root_symlink(source: "../../other/secrets")])

        expect do
          described_class.create_symlinks(
            temp_dir("root"),
            temp_dir("wt"),
            "develop",
            config
          )
        end
          .to raise_error(Orn::Error, /traversal/)
      end

      it "rejects a root dest that traverses" do
        root = temp_dir("root")
        FileUtils.mkdir_p(File.join(root, "legit"))
        config = symlinks(
          root: [
            root_symlink(
              source: "legit",
              dest: "../../.bashrc"
            )
          ]
        )

        expect do
          described_class.create_symlinks(
            root,
            temp_dir("wt"),
            "develop",
            config
          )
        end
          .to raise_error(Orn::Error, /traversal/)
      end
    end

    context "with an empty config" do
      it "does nothing" do
        created, skipped = described_class.create_symlinks(
          temp_dir("root"),
          temp_dir("wt"),
          "develop",
          symlinks
        )

        expect(created).to be_empty
        expect(skipped).to be_empty
      end
    end

    context "with a base-worktree entry" do
      it "creates a relative symlink to the base worktree file" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        base_wt = File.join(root, "develop")
        FileUtils.mkdir_p(File.join(base_wt, ".claude"))
        File.write(File.join(base_wt, ".claude/settings.local.json"), "{}")

        created, skipped = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(base: [".claude/settings.local.json"])
        )

        expect(created).to eq([".claude/settings.local.json"])
        expect(skipped).to be_empty
        link = File.join(wt, ".claude/settings.local.json")
        expect(File.symlink?(link)).to be(true)
        expect(Pathname.new(File.readlink(link))).to be_relative
        expect(File.read(link)).to eq("{}")
      end

      it "silently drops entries when the base worktree is missing" do
        root = temp_dir("root")
        wt = temp_dir("wt")

        created, skipped = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(base: [".env"])
        )

        expect(created).to be_empty
        expect(skipped).to be_empty
        expect(File.exist?(File.join(wt, ".env"))).to be(false)
      end

      it "skips a missing source, reporting the destination" do
        root = temp_dir("root")
        FileUtils.mkdir_p(File.join(root, "develop"))

        created, skipped = described_class.create_symlinks(
          root,
          temp_dir("wt"),
          "develop",
          symlinks(base: ["nonexistent"])
        )

        expect(created).to be_empty
        expect(skipped).to eq(["nonexistent"])
      end

      it "ignores blank entries" do
        root = temp_dir("root")
        FileUtils.mkdir_p(File.join(root, "develop"))

        created, skipped = described_class.create_symlinks(
          root,
          temp_dir("wt"),
          "develop",
          symlinks(base: ["", "  "])
        )

        expect(created).to be_empty
        expect(skipped).to be_empty
      end

      it "skips a destination already occupied by a real file" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        base_wt = File.join(root, "develop")
        FileUtils.mkdir_p(base_wt)
        File.write(File.join(base_wt, ".env"), "from-base")
        File.write(File.join(wt, ".env"), "already-here")

        created, skipped = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(base: [".env"])
        )

        expect(created).to be_empty
        expect(skipped).to eq([".env"])
        expect(File.read(File.join(wt, ".env"))).to eq("already-here")
      end

      it "leaves an already-correct link untouched and silent" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        base_wt = File.join(root, "develop")
        FileUtils.mkdir_p(base_wt)
        File.write(File.join(base_wt, ".env"), "content")
        described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(base: [".env"])
        )

        created, skipped = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(base: [".env"])
        )

        expect(created).to be_empty
        expect(skipped).to be_empty
      end

      it "skips a symlink pointing at the wrong target" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        base_wt = File.join(root, "develop")
        FileUtils.mkdir_p(base_wt)
        File.write(File.join(base_wt, ".env"), "content")
        File.symlink("/tmp/somewhere-else", File.join(wt, ".env"))

        created, skipped = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(base: [".env"])
        )

        expect(created).to be_empty
        expect(skipped).to eq([".env"])
      end
    end

    context "with a root entry" do
      it "creates a symlink named after the source basename by default" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        FileUtils.mkdir_p(File.join(root, "_shared/docs"))

        created, = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(root: [root_symlink(source: "_shared/docs")])
        )

        expect(created).to eq(["docs"])
        expect(File.symlink?(File.join(wt, "docs"))).to be(true)
      end

      it "honors a custom destination" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        FileUtils.mkdir_p(File.join(root, "_shared/docs"))
        File.write(File.join(root, "_shared/docs/readme.md"), "docs")

        created, = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(
            root: [
              root_symlink(
                source: "_shared/docs",
                dest: "shared_docs"
              )
            ]
          )
        )

        expect(created).to eq(["shared_docs"])
        expect(File.read(File.join(wt, "shared_docs/readme.md"))).to eq("docs")
      end
    end

    context "with both base and root entries" do
      it "creates both" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        base_wt = File.join(root, "develop")
        FileUtils.mkdir_p(base_wt)
        File.write(File.join(base_wt, ".env"), "secret")
        FileUtils.mkdir_p(File.join(root, "_"))

        created, skipped = described_class.create_symlinks(
          root,
          wt,
          "develop",
          symlinks(
            base: [".env"],
            root: [root_symlink(source: "_")]
          )
        )

        expect(created).to eq([".env", "_"])
        expect(skipped).to be_empty
      end
    end

    context "when the filesystem rejects the link" do
      it "wraps the error with the destination path" do
        root = temp_dir("root")
        wt = temp_dir("wt")
        base_wt = File.join(root, "develop")
        FileUtils.mkdir_p(File.join(base_wt, "nested"))
        File.write(File.join(base_wt, "nested/config"), "shared")
        File.write(File.join(wt, "nested"), "a file where the link's parent directory should go")

        expect do
          described_class.create_symlinks(
            root,
            wt,
            "develop",
            symlinks(base: ["nested/config"])
          )
        end
          .to raise_error(Orn::Error, %r{symlink .*nested/config: })
      end
    end

    context "when no relative path exists between source and destination" do
      # A relative project root against an absolute worktree gives
      # Pathname#relative_path_from nothing to relate, standing in for the
      # cross-filesystem case.
      it "reports that the relative path could not be computed" do
        workspace = temp_dir("workspace")
        wt = temp_dir("wt")
        base_wt = File.join(workspace, "root/develop")
        FileUtils.mkdir_p(base_wt)
        File.write(File.join(base_wt, ".env"), "secret")

        Dir.chdir(workspace) do
          expect do
            described_class.create_symlinks(
              "root",
              wt,
              "develop",
              symlinks(base: [".env"])
            )
          end
            .to raise_error(Orn::Error, /cannot compute relative path/)
        end
      end
    end
  end

  describe ".gitignored?" do
    context "when git cannot run" do
      it "treats the path as not ignored" do
        wt = temp_dir("wt")

        with_fake_cmd do |fake|
          fake.script_missing(["git", "-C", wt, "check-ignore", "-q", "shared_docs"])

          expect(
            described_class.gitignored?(
              mode,
              wt,
              "shared_docs"
            )
          ).to be(false)
        end
      end
    end

    it "reflects whether git ignores the path" do
      wt = temp_dir("wt")
      init_git_repo(wt)
      File.write(File.join(wt, ".gitignore"), "shared_docs\n")

      expect(
        described_class.gitignored?(
          mode,
          wt,
          "shared_docs"
        )
      ).to be(true)
      expect(
        described_class.gitignored?(
          mode,
          wt,
          "not_ignored"
        )
      ).to be(false)
    end
  end

  describe ".collect_symlink_destinations" do
    it "lists destinations whose source exists and destination is free" do
      root = temp_dir("root")
      FileUtils.mkdir_p(File.join(root, "_shared"))
      config = symlinks(
        root: [
          root_symlink(
            source: "_shared",
            dest: "shared_docs"
          )
        ]
      )

      expect(
        described_class.collect_symlink_destinations(
          root,
          temp_dir("wt"),
          "develop",
          config
        )
      ).to eq(["shared_docs"])
    end

    it "skips a missing source and an occupied destination" do
      root = temp_dir("root")
      wt = temp_dir("wt")
      FileUtils.mkdir_p(File.join(root, "_shared"))
      FileUtils.mkdir_p(File.join(wt, "_shared"))
      occupied = symlinks(root: [root_symlink(source: "_shared")])
      missing = symlinks(root: [root_symlink(source: "nonexistent")])

      expect(
        described_class.collect_symlink_destinations(
          root,
          wt,
          "develop",
          occupied
        )
      ).to be_empty
      expect(
        described_class.collect_symlink_destinations(
          root,
          wt,
          "develop",
          missing
        )
      ).to be_empty
    end
  end

  describe ".find_unignored" do
    it "filters out gitignored destinations" do
      wt = temp_dir("wt")
      init_git_repo(wt)
      File.write(File.join(wt, ".gitignore"), "ignored_path\n")

      expect(
        described_class.find_unignored(
          mode,
          wt,
          %w[ignored_path not_ignored]
        )
      ).to eq(["not_ignored"])
    end
  end

  describe ".add_to_gitignore_and_stage" do
    it "creates the file, appends a trailing newline, and stages it" do
      wt = temp_dir("wt")
      init_git_repo(wt)
      File.write(File.join(wt, ".gitignore"), "existing")

      described_class.add_to_gitignore_and_stage(
        mode,
        wt,
        ["shared_docs"]
      )

      expect(File.read(File.join(wt, ".gitignore"))).to eq("existing\nshared_docs\n")
      staged = `git -C #{wt} diff --cached --name-only`
      expect(staged).to include(".gitignore")
    end

    context "when git cannot run" do
      it "reports that git add could not run" do
        wt = temp_dir("wt")

        with_fake_cmd do |fake|
          fake.script_missing(["git", "-C", wt, "add", ".gitignore"])

          expect do
            described_class.add_to_gitignore_and_stage(
              mode,
              wt,
              ["shared_docs"]
            )
          end
            .to raise_error(Orn::Error, /Failed to run git add .gitignore/)
        end
      end
    end

    context "when git add fails" do
      it "reports git's stderr" do
        wt = temp_dir("wt")

        with_fake_cmd do |fake|
          fake.script(
            ["git", "-C", wt, "add", ".gitignore"],
            stderr: "fatal: not a git repository\n",
            status: 128
          )

          expect do
            described_class.add_to_gitignore_and_stage(
              mode,
              wt,
              ["shared_docs"]
            )
          end
            .to raise_error(Orn::Error, /Failed to stage .gitignore: fatal: not a git repository/)
        end
      end
    end
  end

  describe ".apply" do
    it "creates symlinks and auto-adds unignored destinations to .gitignore" do
      root = temp_dir("root")
      wt = temp_dir("wt")
      init_git_repo(wt)
      FileUtils.mkdir_p(File.join(root, "_shared"))
      config = symlinks(
        root: [
          root_symlink(
            source: "_shared",
            dest: "shared_docs"
          )
        ]
      )

      described_class.apply(
        mode,
        root,
        wt,
        "main",
        config
      ) do |unignored|
        described_class.add_to_gitignore_and_stage(
          mode,
          wt,
          unignored
        )
      end

      expect(File.read(File.join(wt, ".gitignore"))).to include("shared_docs")
      expect(File.symlink?(File.join(wt, "shared_docs"))).to be(true)
    end

    it "does not invoke the block when all destinations are gitignored" do
      root = temp_dir("root")
      wt = temp_dir("wt")
      init_git_repo(wt)
      File.write(File.join(wt, ".gitignore"), "_shared\n")
      FileUtils.mkdir_p(File.join(root, "_shared"))
      config = symlinks(root: [root_symlink(source: "_shared")])

      described_class.apply(
        mode,
        root,
        wt,
        "main",
        config
      ) { raise "should not be called" }

      expect(File.symlink?(File.join(wt, "_shared"))).to be(true)
    end

    it "propagates a block error and creates no symlinks" do
      root = temp_dir("root")
      wt = temp_dir("wt")
      init_git_repo(wt)
      FileUtils.mkdir_p(File.join(root, "_shared"))
      config = symlinks(root: [root_symlink(source: "_shared")])

      expect do
        described_class.apply(
          mode,
          root,
          wt,
          "main",
          config
        ) { raise Orn::Error, "declined" }
      end
        .to raise_error(Orn::Error, /declined/)
      expect(File.symlink?(File.join(wt, "_shared"))).to be(false)
    end
  end
end
