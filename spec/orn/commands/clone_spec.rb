# frozen_string_literal: true

RSpec.describe Orn::Commands::Clone do
  describe ".derive_project_name" do
    it "takes the last path segment and strips a .git suffix" do
      expect(described_class.derive_project_name("git@github.com:org/my-project.git")).to eq("my-project")
      expect(described_class.derive_project_name("https://github.com/org/my-project.git")).to eq("my-project")
      expect(described_class.derive_project_name("https://github.com/org/my-project")).to eq("my-project")
    end

    it "rejects a URL whose last segment leaves no name" do
      expect { described_class.derive_project_name("https://github.com/org/.git") }
        .to raise_error(Orn::Error, /Could not derive project name/)
    end
  end

  describe "#run", :real_cmd do
    it "clones a remote into a new bare-worktree project" do
      remote = make_remote_with_branch("feature/x")
      work = register_temp_dir(Dir.mktmpdir("orn-clone-work"))
      isolate_global_config

      name = described_class.derive_project_name(remote)
      Dir.chdir(work) do
        described_class.new(output_mode: Orn::OutputMode.quiet).run(remote, "main")
      end

      project = File.join(work, name)
      expect(File.directory?(File.join(project, ".bare"))).to be(true)
      expect(File.read(File.join(project, ".git"))).to eq("gitdir: ./.bare\n")
      expect(File.exist?(File.join(project, ".orn/config.yaml"))).to be(true)
      expect(File.directory?(File.join(project, "main"))).to be(true)
    end

    it "removes the project directory and re-raises when the clone fails" do
      work = register_temp_dir(Dir.mktmpdir("orn-clone-work"))
      url = "git@host:org/my-project.git"
      clone_argv = [
        "git",
        "-C",
        "my-project",
        "clone",
        "--bare",
        "--",
        url,
        ".bare"
      ]

      with_fake_cmd do |fake|
        fake.script(
          clone_argv,
          stderr: "fatal: repository not found",
          status: 128
        )

        Dir.chdir(work) do
          expect { described_class.new(output_mode: Orn::OutputMode.quiet).run(url, "main") }
            .to raise_error(Orn::Error, /git failed: fatal: repository not found/)
        end
      end

      expect(File.exist?(File.join(work, "my-project"))).to be(false)
    end

    it "removes the project directory when interrupted mid-clone" do
      work = register_temp_dir(Dir.mktmpdir("orn-clone-work"))
      allow(Orn::Commands::Setup).to receive(:clone_into).and_raise(Interrupt)

      Dir.chdir(work) do
        expect { described_class.new(output_mode: Orn::OutputMode.quiet).run("git@host:org/my-project.git", "main") }
          .to raise_error(Interrupt)
      end

      expect(File.exist?(File.join(work, "my-project"))).to be(false)
    end

    it "rejects a URL that looks like a git option" do
      with_fake_cmd do |fake|
        expect { described_class.new(output_mode: Orn::OutputMode.quiet).run("--upload-pack=evil", "main") }
          .to raise_error(Orn::Error, /Invalid repository URL '--upload-pack=evil'/)
        expect(fake.invocations).to be_empty
      end
    end

    it "refuses to overwrite an existing directory" do
      work = register_temp_dir(Dir.mktmpdir("orn-clone-work"))
      Dir.chdir(work) { FileUtils.mkdir("taken") }

      Dir.chdir(work) do
        expect { described_class.new(output_mode: Orn::OutputMode.quiet).run("git@host:org/taken.git", "main") }
          .to raise_error(Orn::Error, /already exists/)
      end
    end
  end
end
