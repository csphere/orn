# frozen_string_literal: true

require "json"

RSpec.describe Orn::Commands::Wt::Open do
  def standard_project(branch)
    remote = make_remote_with_branch(branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(
      File.join(
        project,
        ".orn",
        "config.yaml"
      ),
      "git:\n  base: main\n"
    )
    project
  end

  def load_project(root)
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  describe ".resolve" do
    it "returns the existing worktree path without creating anything" do
      root = standard_project("feature/other")
      FileUtils.mkdir_p(File.join(root, "feature/local"))

      result = described_class.resolve(
        Orn::OutputMode.quiet,
        load_project(root),
        "feature/local"
      )

      aggregate_failures do
        expect(result.created).to be(false)
        expect(result.path).to eq(File.join(root, "feature/local"))
      end
    end

    it "creates the worktree from the remote branch when it is not local" do
      root = standard_project("feature/remote-only")

      result = described_class.resolve(
        Orn::OutputMode.quiet,
        load_project(root),
        "feature/remote-only"
      )

      aggregate_failures do
        expect(result.created).to be(true)
        expect(File).to exist(
          File.join(
            root,
            "feature/remote-only",
            "g.txt"
          )
        )
      end
    end

    it "raises when the branch exists neither locally nor on the remote" do
      root = standard_project("feature/other")

      expect do
        described_class.resolve(
          Orn::OutputMode.quiet,
          load_project(root),
          "feature/missing"
        )
      end
        .to raise_error(Orn::Error, /No worktree found for.*does not exist on the remote/m)
    end
  end

  describe "#run" do
    def run_command(output_mode)
      described_class.new(output_mode: output_mode)
    end

    # A project the command can rediscover from inside its root, with the
    # global config isolated so nothing outside the temp dirs is read.
    def discoverable_project(branch)
      isolate_global_config
      File.realpath(standard_project(branch))
    end

    it "rejects an invalid branch name before touching git" do
      expect { run_command(Orn::OutputMode.default).run("bad..name") }
        .to raise_error(Orn::Error, /Invalid branch name 'bad\.\.name'/)
    end

    it "prints the existing-worktree wording when the worktree is already on disk" do
      root = discoverable_project("feature/other")
      wt_path = File.join(root, "feature/local")
      FileUtils.mkdir_p(wt_path)

      expect { Dir.chdir(root) { run_command(Orn::OutputMode.default).run("feature/local") } }
        .to output("Worktree: #{wt_path}\n").to_stdout
    end

    it "prints the created-from-remote wording when the branch exists only on origin" do
      root = discoverable_project("feature/remote-only")
      wt_path = File.join(root, "feature/remote-only")

      expect { Dir.chdir(root) { run_command(Orn::OutputMode.default).run("feature/remote-only") } }
        .to output("Created worktree from remote: #{wt_path}\n").to_stdout
        .and output(%r{Checking remote for feature/remote-only}).to_stderr
    end

    it "prints the result as JSON in JSON mode" do
      root = discoverable_project("feature/other")
      wt_path = File.join(root, "feature/local")
      FileUtils.mkdir_p(wt_path)
      expected_json = JSON.pretty_generate(
        branch: "feature/local",
        path: wt_path,
        created: false
      )

      expect { Dir.chdir(root) { run_command(Orn::OutputMode.quiet).run("feature/local") } }
        .to output("#{expected_json}\n").to_stdout
    end
  end
end
