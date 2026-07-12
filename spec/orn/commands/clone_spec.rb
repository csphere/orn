# frozen_string_literal: true

RSpec.describe Orn::Commands::Clone do
  describe ".derive_project_name" do
    it "takes the last path segment and strips a .git suffix" do
      expect(described_class.derive_project_name("git@github.com:org/my-project.git")).to eq("my-project")
      expect(described_class.derive_project_name("https://github.com/org/my-project.git")).to eq("my-project")
      expect(described_class.derive_project_name("https://github.com/org/my-project")).to eq("my-project")
    end
  end

  describe "#run" do
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

    it "refuses to overwrite an existing directory" do
      work = register_temp_dir(Dir.mktmpdir("orn-clone-work"))
      Dir.chdir(work) { FileUtils.mkdir("taken") }

      Dir.chdir(work) do
        expect { described_class.new(output_mode: Orn::OutputMode.quiet).run("git@host:org/taken.git", "main") }
          .to raise_error(Orn::Error, /already exists/)
      end
    end
  end

  # Points the global config at a fresh dir with an existing default.yaml, so
  # scaffolding's global-config bootstrap skips (no interactive prompt).
  def isolate_global_config
    xdg = register_temp_dir(Dir.mktmpdir("orn-xdg"))
    FileUtils.mkdir_p(File.join(xdg, "orn"))
    File.write(File.join(xdg, "orn/default.yaml"), "")
    ENV["XDG_CONFIG_HOME"] = xdg
  end
end
