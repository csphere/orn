# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

RSpec.describe Orn::Commands::Wt::New do
  def standard_project(branch = "feature/existing", config_yaml = "git:\n  base: main\n")
    remote = make_remote_with_branch(branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(
      File.join(
        project,
        ".orn",
        "config.yaml"
      ),
      config_yaml
    )
    project
  end

  def load_project(root)
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  # A project whose config links the named project-root files into each new
  # worktree. The files exist at the root but nothing gitignores them, so
  # creating a worktree triggers the unignored-destination flow.
  def project_with_root_symlinks(source_names)
    entries = source_names.map { |name| "    - source: #{name}\n" }.join
    root = standard_project(
      "feature/existing",
      "git:\n  base: main\nsymlinks:\n  root:\n#{entries}"
    )
    source_names.each { |name| File.write(File.join(root, name), "shared") }
    root
  end

  def with_stdin(reader)
    original_stdin = $stdin
    $stdin = reader
    yield
  ensure
    $stdin = original_stdin
  end

  def tty_reader(input)
    reader = StringIO.new(input)
    reader.define_singleton_method(:tty?) { true }
    reader
  end

  # Runs the block against a fake interactive terminal: stdin serves `input`
  # and claims to be a tty, stderr is captured. Returns the block result and
  # the captured prompt output.
  def with_interactive_stdin(input, &block)
    with_stdin_and_captured_stderr(tty_reader(input), &block)
  end

  # Runs the block with a stdin that is not a tty (like a pipe), capturing
  # stderr. Returns the block result and the captured output.
  def with_noninteractive_stdin(&block)
    with_stdin_and_captured_stderr(StringIO.new, &block)
  end

  def with_stdin_and_captured_stderr(reader, &block)
    original_stderr = $stderr
    $stderr = StringIO.new
    result = with_stdin(reader, &block)
    [result, $stderr.string]
  ensure
    $stderr = original_stderr
  end

  describe ".create" do
    it "creates a worktree tracking the remote branch when it exists" do
      root = standard_project("feature/existing")

      result = described_class.create(
        Orn::OutputMode.quiet,
        load_project(root),
        "feature/existing",
        nil
      )

      aggregate_failures do
        expect(result.from_remote).to be(true)
        expect(result.branch).to eq("feature/existing")
        expect(File).to exist(
          File.join(
            root,
            "feature/existing",
            "g.txt"
          )
        )
      end
    end

    it "creates a worktree off base when the branch is new" do
      root = standard_project("feature/other")

      result = described_class.create(
        Orn::OutputMode.quiet,
        load_project(root),
        "feature/brand-new",
        nil
      )

      aggregate_failures do
        expect(result.from_remote).to be(false)
        expect(result.base).to eq("main")
        expect(File).to be_directory(File.join(root, "feature/brand-new"))
      end
    end

    it "raises when the worktree already exists" do
      root = standard_project("feature/existing")
      FileUtils.mkdir_p(File.join(root, "feature/existing"))

      expect do
        described_class.create(
          Orn::OutputMode.quiet,
          load_project(root),
          "feature/existing",
          nil
        )
      end
        .to raise_error(Orn::Error, /already exists/)
    end
  end

  describe ".create with a symlink destination that is not gitignored" do
    it "adds the destination to .gitignore and links it when the user confirms" do
      root = project_with_root_symlinks(["shared.txt"])
      wt_path = File.join(root, "feature/new")

      result, prompt = with_interactive_stdin("y\n") do
        described_class.create(
          Orn::OutputMode.default,
          load_project(root),
          "feature/new",
          nil
        )
      end

      aggregate_failures do
        expect(prompt).to include("warning: symlink destination 'shared.txt' is not in .gitignore")
        expect(prompt).to include("Proceed? [y/n]")
        expect(result.branch).to eq("feature/new")
        expect(File.read(File.join(wt_path, ".gitignore"))).to eq("shared.txt\n")
        expect(File).to be_symlink(File.join(wt_path, "shared.txt"))
      end
    end

    it "removes the new worktree and aborts when the user declines" do
      root = project_with_root_symlinks(["shared.txt"])
      wt_path = File.join(root, "feature/new")

      with_interactive_stdin("n\n") do
        expect do
          described_class.create(
            Orn::OutputMode.default,
            load_project(root),
            "feature/new",
            nil
          )
        end
          .to raise_error(Orn::Error, "Aborted")
      end

      expect(File).not_to exist(wt_path)
    end

    it "removes the worktree and raises naming the path when stdin is not a terminal" do
      root = project_with_root_symlinks(["shared.txt"])
      wt_path = File.join(root, "feature/new")

      _, stderr_output = with_noninteractive_stdin do
        expect do
          described_class.create(
            Orn::OutputMode.default,
            load_project(root),
            "feature/new",
            nil
          )
        end
          .to raise_error(
            Orn::Error,
            "symlink destination not in .gitignore: 'shared.txt'\n" \
              "Add it to .gitignore before running 'orn new'"
          )
      end

      aggregate_failures do
        expect(stderr_output).to include("Creating worktree")
        expect(File).not_to exist(wt_path)
      end
    end

    it "lists every path with plural wording in JSON mode" do
      root = project_with_root_symlinks(
        [
          "shared_one.txt",
          "shared_two.txt"
        ]
      )
      wt_path = File.join(root, "feature/new")

      expect do
        described_class.create(
          Orn::OutputMode.quiet,
          load_project(root),
          "feature/new",
          nil
        )
      end
        .to raise_error(
          Orn::Error,
          "symlink destinations not in .gitignore: 'shared_one.txt', 'shared_two.txt'\n" \
            "Add them to .gitignore before running 'orn new'"
        )
      expect(File).not_to exist(wt_path)
    end

    it "still reports the gitignore problem when removing the worktree fails" do
      root = register_temp_dir(Dir.mktmpdir("orn-wt-new"))
      project = make_project(root, "git:\n  base: main\nsymlinks:\n  root:\n    - source: shared.txt\n")
      File.write(File.join(root, "shared.txt"), "shared")
      wt_path = File.join(root, "feature/new")
      remove_argv = [
        "git",
        "-C",
        root,
        "worktree",
        "remove",
        "--force",
        wt_path
      ]

      with_fake_cmd do |fake|
        fake.script(["git", "-C", root, "fetch", "origin", "main"])
        fake.script(["git", "-C", root, "ls-remote", "--heads", "origin", "feature/new"])
        fake.script(["git", "-C", root, "worktree", "add", "-b", "feature/new", wt_path, "origin/main"])
        fake.script(["git", "-C", wt_path, "check-ignore", "-q", "shared.txt"], status: 1)
        fake.script(
          remove_argv,
          stderr: "cleanup failed",
          status: 1
        )

        expect do
          described_class.create(
            Orn::OutputMode.quiet,
            project,
            "feature/new",
            nil
          )
        end
          .to raise_error(Orn::Error, /not in \.gitignore/)

        expect(fake.invocations).to include(remove_argv)
      end
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

    it "rejects an invalid base override before touching git" do
      expect { run_command(Orn::OutputMode.default).run("feat", base_override: "base..bad") }
        .to raise_error(Orn::Error, /Invalid branch name 'base\.\.bad'/)
    end

    it "prints the based-on wording for a branch created off base" do
      root = discoverable_project("feature/other")
      wt_path = File.join(root, "feature/fresh")

      expect { Dir.chdir(root) { run_command(Orn::OutputMode.default).run("feature/fresh") } }
        .to output("Created worktree: #{wt_path}\nBranch: feature/fresh (based on main)\n").to_stdout
        .and output(/Creating worktree at/).to_stderr
    end

    it "prints the from-remote wording when the branch exists on origin" do
      root = discoverable_project("feature/existing")
      wt_path = File.join(root, "feature/existing")

      expect { Dir.chdir(root) { run_command(Orn::OutputMode.default).run("feature/existing") } }
        .to output("Created worktree: #{wt_path}\nBranch: feature/existing (from remote)\n").to_stdout
        .and output(%r{Fetching origin/main}).to_stderr
    end

    it "prints the result as JSON in JSON mode" do
      root = discoverable_project("feature/other")
      expected_json = JSON.pretty_generate(
        branch: "feature/fresh",
        base: "main",
        worktree_path: File.join(root, "feature/fresh"),
        from_remote: false
      )

      expect { Dir.chdir(root) { run_command(Orn::OutputMode.quiet).run("feature/fresh") } }
        .to output("#{expected_json}\n").to_stdout
    end
  end
end
