# frozen_string_literal: true

RSpec.describe Orn::Commands::Remove do
  let(:client) { FakeTmuxClient.new }

  def project_with_worktree(branch)
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
    worktree = Orn::Git::Worktree.new(
      root: project,
      output_mode: Orn::OutputMode.quiet
    )
    worktree.fetch("origin", branch)
    worktree.add(
      File.join(project, branch),
      branch,
      "origin/#{branch}"
    )
    project
  end

  def load_project(root)
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  def result(branch:, sandbox_removed:, window_closed:)
    wt = Orn::Commands::Wt::Remove::Result.new(
      branch: branch,
      worktree_removed: true,
      branch_deleted: false,
      remote_branch_deleted: false
    )
    described_class::Result.new(
      sandbox_removed: sandbox_removed,
      window_closed: window_closed,
      wt: wt
    )
  end

  def sandbox_project
    # Realpath so scripted argvs match the root Project.discover resolves
    # (macOS realpaths /var temp dirs to /private/var).
    make_project(File.realpath(make_bare_project), "tmux:\n  session: proj\n")
  end

  describe "Result#print_summary" do
    it "prints the sandbox and window lines above the worktree summary" do
      summary = result(
        branch: "feature/x",
        sandbox_removed: true,
        window_closed: true
      )

      expect { summary.print_summary }.to output(<<~OUTPUT).to_stdout
        Removed sandbox for feature/x
        Closed tmux window: feature/x
        Removed worktree: feature/x
      OUTPUT
    end
  end

  describe "#run_inner" do
    it "removes the sandbox with its ports file and closes the window" do
      project = sandbox_project
      Orn::Sandbox::Ports.persist_ports(
        File.join(project.root, ".orn"),
        "proj-feat",
        [
          Orn::Sandbox::PortMapping.new(
            host: 3042,
            container: 3000
          )
        ]
      )
      ports_path = File.join(
        project.root,
        ".orn",
        "sandbox",
        "proj-feat.ports"
      )
      command = described_class.new(
        output_mode: Orn::OutputMode.quiet,
        client: client
      )
      client.windows = { "proj" => ["feat"] }

      with_fake_cmd do |fake|
        fake.script(%w[sbx rm --force proj-feat])

        removal = command.run_inner(
          project,
          "feat",
          false
        )

        aggregate_failures do
          expect(removal.sandbox_removed).to be(true)
          expect(removal.window_closed).to be(true)
          expect(client.calls).to include([:kill_window, "proj", "feat"])
          expect(File).not_to exist(ports_path)
        end
      end
    end

    it "raises before touching the sandbox or window when run from inside the worktree" do
      project = sandbox_project
      wt_path = File.join(project.root, "feat")
      FileUtils.mkdir_p(wt_path)
      command = described_class.new(
        output_mode: Orn::OutputMode.quiet,
        client: client
      )
      client.windows = { "proj" => ["feat"] }

      with_fake_cmd do |fake|
        Dir.chdir(wt_path) do
          expect do
            command.run_inner(
              project,
              "feat",
              false
            )
          end.to raise_error(Orn::Error, /while inside it/)
        end

        aggregate_failures do
          expect(fake.invocations).to be_empty
          expect(client.calls).not_to include([:kill_window, "proj", "feat"])
        end
      end
    end
  end

  describe "#run" do
    # Scripts every command a pruning removal issues for `branch` as a
    # failure, so no sandbox, window, or git branch is found.
    def script_nothing_to_remove(fake, project, branch)
      sandbox = "proj-#{branch.tr("/", "-")}"
      fake.script(
        ["sbx", "rm", "--force", sandbox],
        status: 1
      )
      fake.script(
        ["git", "-C", project.root, "branch", "-D", branch],
        status: 1
      )
      fake.script(
        ["git", "-C", project.root, "push", "origin", "--delete", branch],
        status: 1
      )
    end

    it "prompts for each branch before pruning interactively" do
      project = sandbox_project
      isolate_global_config
      command = described_class.new(
        output_mode: Orn::OutputMode.default,
        client: client
      )
      allow(Orn::Confirm).to receive(:prune_interactive)

      with_fake_cmd do |fake|
        %w[feature/a feature/b].each { |branch| script_nothing_to_remove(fake, project, branch) }

        expect do
          Dir.chdir(project.root) do
            command.run(
              %w[feature/a feature/b],
              prune: true,
              force: false
            )
          end
        end.to output("No worktree found for feature/a\nNo worktree found for feature/b\n").to_stdout
      end

      expect(Orn::Confirm).to have_received(:prune_interactive).with(project.root, "feature/a")
      expect(Orn::Confirm).to have_received(:prune_interactive).with(project.root, "feature/b")
    end
  end

  describe "result JSON shape" do
    it "flattens the worktree fields alongside the sandbox and window flags" do
      json = result(
        branch: "feature/x",
        sandbox_removed: true,
        window_closed: true
      ).to_json_hash

      expect(json).to include(
        "sandbox_removed" => true,
        "window_closed" => true,
        "branch" => "feature/x"
      )
    end

    it "reports sandbox_removed false when no sandbox was torn down" do
      json = result(
        branch: "feature/y",
        sandbox_removed: false,
        window_closed: false
      ).to_json_hash

      expect(json["sandbox_removed"]).to be(false)
    end
  end

  context "with a real tmux server", :real_cmd, if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    it "closes the tmux window and removes the worktree" do
      project = project_with_worktree("feature/gone")
      real_client = Orn::Tmux::Client.new(output_mode: Orn::OutputMode.quiet)

      Dir.chdir(project) do
        real_client.open_window(load_project(project), "feature/gone")
        described_class.new(output_mode: Orn::OutputMode.quiet).run(
          ["feature/gone"],
          prune: false,
          force: false
        )
      end

      session = Orn::Session.session_name(load_project(project))
      aggregate_failures do
        expect(File).not_to exist(File.join(project, "feature/gone"))
        expect(real_client.window_exists?(session, "feature/gone")).to be(false)
      end
    end

    it "reports window_closed false when there is no window" do
      project = project_with_worktree("feature/nowin")
      command = described_class.new(output_mode: Orn::OutputMode.quiet)

      expect do
        Dir.chdir(project) do
          command.run(
            ["feature/nowin"],
            prune: false,
            force: false
          )
        end
      end
        .to output(/"window_closed": false/).to_stdout
    end
  end
end
