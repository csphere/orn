# frozen_string_literal: true

RSpec.describe Orn::Commands::Remove do
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

  context "with a real tmux server", if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    it "closes the tmux window and removes the worktree" do
      project = project_with_worktree("feature/gone")

      Dir.chdir(project) do
        Orn::Tmux.open_window(
          Orn::OutputMode.quiet,
          load_project(project),
          "feature/gone"
        )
        described_class.new(output_mode: Orn::OutputMode.quiet).run(
          ["feature/gone"],
          prune: false,
          force: false
        )
      end

      session = Orn::Session.session_name(load_project(project))
      aggregate_failures do
        expect(File).not_to exist(File.join(project, "feature/gone"))
        expect(
          Orn::Tmux.window_exists?(
            Orn::OutputMode.quiet,
            session,
            "feature/gone"
          )
        ).to be(false)
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
