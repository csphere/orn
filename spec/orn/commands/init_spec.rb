# frozen_string_literal: true

require "yaml"

RSpec.describe Orn::Commands::Init do
  describe ".derive_project_name" do
    it "is the target directory's basename" do
      expect(described_class.derive_project_name("/home/user/my-project")).to eq("my-project")
      expect(described_class.derive_project_name("/home/user/dev/acme-api")).to eq("acme-api")
    end
  end

  describe "#run_in" do
    subject(:command) { described_class.new(output_mode: Orn::OutputMode.quiet) }

    before { isolate_global_config }

    def project_dir(name = "my-project")
      dir = File.join(register_temp_dir(Dir.mktmpdir("orn-init")), name)
      FileUtils.mkdir_p(dir)
      dir
    end

    def base_config(dir)
      YAML.safe_load_file(File.join(dir, ".orn/config.yaml"))
    end

    context "when the directory is empty" do
      it "creates the bare repo, pointer, config, CLAUDE.md, and base worktree" do
        dir = project_dir

        command.run_in(dir, "main")

        aggregate_failures do
          expect(File.exist?(File.join(dir, ".bare/HEAD"))).to be(true)
          expect(File.read(File.join(dir, ".git"))).to eq("gitdir: ./.bare\n")
          expect(base_config(dir).dig("git", "base")).to eq("main")
          expect(File.read(File.join(dir, "CLAUDE.md"))).to include(".bare", "main/")
          expect(File.exist?(File.join(dir, "main/.git"))).to be(true)
        end
      end

      it "gives the base branch an initial commit with an empty tree" do
        dir = project_dir
        worktree = File.join(dir, "main")

        command.run_in(dir, "main")

        expect(`git -C #{worktree} log --oneline`).to include("Initial commit")
        expect(`git -C #{worktree} ls-tree HEAD`.strip).to be_empty
      end

      it "respects a custom base branch" do
        dir = project_dir

        command.run_in(dir, "develop")

        expect(File.directory?(File.join(dir, "develop"))).to be(true)
        expect(base_config(dir).dig("git", "base")).to eq("develop")
      end

      it "uses the directory name in CLAUDE.md" do
        dir = project_dir("acme-api")

        command.run_in(dir, "main")

        expect(File.read(File.join(dir, "CLAUDE.md"))).to include("acme-api")
      end
    end

    context "when the directory already looks like a project" do
      it "refuses a .git, .bare, or .orn already present" do
        %w[.git .bare .orn].each do |marker|
          dir = project_dir
          FileUtils.mkdir_p(File.join(dir, marker))

          expect { command.run_in(dir, "main") }.to raise_error(Orn::Error, /already contains/)
        end
      end
    end

    context "when a step fails" do
      it "rolls back the created files" do
        dir = project_dir
        File.write(File.join(dir, "main"), "blocker") # makes `git worktree add main` fail

        expect { command.run_in(dir, "main") }.to raise_error(Orn::Error)

        expect(File.exist?(File.join(dir, ".bare"))).to be(false)
        expect(File.exist?(File.join(dir, ".orn"))).to be(false)
      end
    end
  end
end
