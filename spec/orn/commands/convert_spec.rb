# frozen_string_literal: true

RSpec.describe Orn::Commands::Convert, :real_cmd do
  subject(:command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

  def git!(dir, *args)
    system(
      GitHelpers::GIT_ISOLATION_ENV,
      "git",
      "-C",
      dir,
      *args,
      out: File::NULL,
      err: File::NULL
    )
  end

  describe "#check_guards" do
    context "when the repo is convertible" do
      it "passes and returns the discovered origin and branch" do
        guards = command.check_guards(make_standard_repo, nil)

        expect(guards.current_branch).to eq("main")
        expect(guards.origin_url).not_to be_empty
      end

      it "allows untracked files" do
        dir = make_standard_repo
        File.write(File.join(dir, "untracked.txt"), "new")

        expect { command.check_guards(dir, nil) }.not_to raise_error
      end

      it "allows a detached HEAD when --base is given" do
        dir = make_standard_repo
        git!(
          dir,
          "checkout",
          `git -C #{dir} rev-parse HEAD`.strip
        )

        expect { command.check_guards(dir, "main") }.not_to raise_error
      end
    end

    context "when a precondition is violated" do
      it "rejects a directory that is not a git repo" do
        dir = register_temp_dir(Dir.mktmpdir("orn-plain"))

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /Not inside a git repository/)
      end

      it "rejects a directory that is already a bare-worktree project" do
        dir = register_temp_dir(Dir.mktmpdir("orn-bare"))
        File.write(File.join(dir, ".git"), "gitdir: ./.bare\n")

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /Already a bare worktree project/)
      end

      it "rejects a repo with submodules" do
        dir = make_standard_repo
        File.write(File.join(dir, ".gitmodules"), "[submodule]")

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /submodules/)
      end

      it "rejects a repo with extra worktrees" do
        dir = make_standard_repo
        git!(
          dir,
          "branch",
          "other"
        )
        wt_other = File.join(register_temp_dir(Dir.mktmpdir("orn-wt")), "other")
        git!(
          dir,
          "worktree",
          "add",
          wt_other,
          "other"
        )

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /multiple worktrees/)
      end

      it "rejects a dirty working tree" do
        dir = make_standard_repo
        File.write(File.join(dir, "file.txt"), "modified")

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /uncommitted changes/)
      end

      it "rejects a repo with no origin remote" do
        dir = register_temp_dir(Dir.mktmpdir("orn-noorigin"))
        git!(
          dir,
          "init",
          "-b",
          "main"
        )
        git!(
          dir,
          "config",
          "user.email",
          "t@t.com"
        )
        git!(
          dir,
          "config",
          "user.name",
          "T"
        )
        File.write(File.join(dir, "f.txt"), "x")
        git!(
          dir,
          "add",
          "."
        )
        git!(
          dir,
          "commit",
          "-m",
          "init"
        )

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /No 'origin' remote/)
      end

      it "rejects a detached HEAD without --base" do
        dir = make_standard_repo
        git!(
          dir,
          "checkout",
          `git -C #{dir} rev-parse HEAD`.strip
        )

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /HEAD is detached/)
      end

      it "rejects unpushed commits" do
        dir = make_standard_repo
        File.write(File.join(dir, "new.txt"), "data")
        git!(
          dir,
          "add",
          "."
        )
        git!(
          dir,
          "commit",
          "-m",
          "unpushed"
        )

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /unpushed commits/)
      end

      it "rejects local-only branches, naming them" do
        dir = make_standard_repo
        git!(
          dir,
          "branch",
          "local-only"
        )

        expect { command.check_guards(dir, nil) }.to raise_error(Orn::Error, /Local-only branches.*local-only/m)
      end
    end
  end

  describe "#resolve_base_branch" do
    it "returns the current branch when it matches the remote default" do
      expect(
        command.resolve_base_branch(
          make_repo_with_remote_head,
          nil,
          nil
        )
      ).to eq("main")
    end

    it "falls back to the current branch when no remote default is recorded" do
      expect(
        command.resolve_base_branch(
          make_standard_repo,
          nil,
          nil
        )
      ).to eq("main")
    end

    it "ignores a remote HEAD symref outside origin's namespace" do
      dir = make_standard_repo
      git!(
        dir,
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/heads/main"
      )

      expect(
        command.resolve_base_branch(
          dir,
          nil,
          nil
        )
      ).to eq("main")
    end

    it "rejects a mismatch, suggesting --base" do
      dir = make_repo_with_remote_head
      git!(
        dir,
        "checkout",
        "-b",
        "feature/xyz"
      )

      expect do
        command.resolve_base_branch(
          dir,
          nil,
          nil
        )
      end
        .to raise_error(Orn::Error, %r{feature/xyz.*main.*--base}m)
    end

    it "honors an explicit base over a mismatch" do
      dir = make_repo_with_remote_head
      git!(
        dir,
        "checkout",
        "-b",
        "feature/xyz"
      )

      expect(
        command.resolve_base_branch(
          dir,
          "main",
          nil
        )
      ).to eq("main")
    end

    it "validates an explicit base branch name" do
      expect do
        command.resolve_base_branch(
          make_standard_repo,
          "bad..name",
          nil
        )
      end
        .to raise_error(Orn::Error, /'\.\.'/)
    end
  end

  # A convertible repo whose origin remote still exists, so the re-clone
  # inside convert succeeds. Returns the repo path.
  def make_repo_with_live_origin
    remote = register_temp_dir(Dir.mktmpdir("orn-live-remote"))
    git!(
      remote,
      "init",
      "--bare"
    )
    dir = register_temp_dir(Dir.mktmpdir("orn-live"))
    git!(
      dir,
      "init",
      "-b",
      "main"
    )
    git!(
      dir,
      "config",
      "user.email",
      "t@t.com"
    )
    git!(
      dir,
      "config",
      "user.name",
      "T"
    )
    git!(
      dir,
      "remote",
      "add",
      "origin",
      remote
    )
    File.write(File.join(dir, "file.txt"), "content")
    git!(
      dir,
      "add",
      "."
    )
    git!(
      dir,
      "commit",
      "-m",
      "init"
    )
    git!(
      dir,
      "push",
      "-u",
      "origin",
      "main"
    )
    dir
  end

  describe "#run" do
    it "converts the current directory" do
      dir = make_standard_repo # origin URL dangles, so clone fails

      Dir.chdir(dir) do
        expect { command.run(nil) }.to raise_error(Orn::Error, /restored/)
      end

      expect(File.exist?(File.join(dir, "file.txt"))).to be(true)
    end
  end

  describe "#run_in" do
    it "refuses to run when the backup path already exists" do
      dir = make_standard_repo
      FileUtils.mkdir("#{dir}.pre-orn")

      expect { command.run_in(dir, nil) }.to raise_error(Orn::Error, /already exists/)
    ensure
      FileUtils.rm_rf("#{dir}.pre-orn")
    end

    it "restores the original repo when the re-clone fails" do
      dir = make_standard_repo # origin URL dangles, so clone fails

      expect { command.run_in(dir, nil) }.to raise_error(Orn::Error, /restored/)

      expect(File.exist?(File.join(dir, "file.txt"))).to be(true)
      expect(File.directory?(File.join(dir, ".git"))).to be(true)
      expect(File.exist?("#{dir}.pre-orn")).to be(false)
    end

    it "restores the original repo when interrupted mid-clone" do
      dir = make_standard_repo
      allow(Orn::Commands::Setup).to receive(:clone_into).and_raise(Interrupt)

      expect { command.run_in(dir, nil) }.to raise_error(Orn::Error, /restored/)

      expect(File.exist?(File.join(dir, "file.txt"))).to be(true)
      expect(File.exist?("#{dir}.pre-orn")).to be(false)
    end

    it "reports the backup location when restoring the backup also fails" do
      dir = make_standard_repo # origin URL dangles, so clone fails
      backup_path = "#{dir}.pre-orn"
      register_temp_dir(backup_path)
      allow(FileUtils).to receive(:mv).and_call_original
      allow(FileUtils).to receive(:mv).with(backup_path, dir).and_raise(Errno::EACCES)

      expect { command.run_in(dir, nil) }
        .to raise_error(Orn::Error, /could not restore backup.*#{Regexp.escape(backup_path)}/)
    end

    it "converts with an explicit base, keeps the backup, and prints next steps" do
      dir = make_repo_with_live_origin
      register_temp_dir("#{dir}.pre-orn")
      isolate_global_config
      dir_name = File.basename(dir)
      status_command = described_class.new(output_mode: Orn::OutputMode.default)

      next_steps = %r{Done\. Converted to orn project at \./#{Regexp.escape(dir_name)}.*Check backup for gitignored}m
      expect { status_command.run_in(dir, "main") }
        .to output(next_steps)
        .to_stderr

      expect(File.read(File.join(dir, ".git"))).to eq("gitdir: ./.bare\n")
      expect(File.directory?(File.join(dir, "main"))).to be(true)
      expect(File.exist?(File.join(dir, "main/file.txt"))).to be(true)
      expect(File.directory?("#{dir}.pre-orn")).to be(true)
    end
  end
end
