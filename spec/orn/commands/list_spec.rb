# frozen_string_literal: true

RSpec.describe Orn::Commands::List do
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

  context "with a real tmux server", if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    describe "#run_inner" do
      it "marks a worktree with no tmux window" do
        project = project_with_worktree("feature/listed")

        result = described_class.new(output_mode: Orn::OutputMode.quiet).run_inner(load_project(project))

        entry = result.worktrees.find { |candidate| candidate.branch == "feature/listed" }
        aggregate_failures do
          expect(entry).not_to be_nil
          expect(entry.has_window).to be(false)
        end
      end

      it "marks a worktree that has an open tmux window" do
        project = project_with_worktree("feature/listed")
        loaded = load_project(project)

        result = Dir.chdir(project) do
          Orn::Tmux.open_window(
            Orn::OutputMode.quiet,
            loaded,
            "feature/listed"
          )
          described_class.new(output_mode: Orn::OutputMode.quiet).run_inner(loaded)
        end

        entry = result.worktrees.find { |candidate| candidate.branch == "feature/listed" }
        expect(entry.has_window).to be(true)
      end
    end

    describe "#run" do
      it "prints a Branch/Status table for humans" do
        project = project_with_worktree("feature/listed")
        command = described_class.new(output_mode: Orn::OutputMode.default)

        expect { Dir.chdir(project) { command.run } }.to output(%r{feature/listed.*no window}m).to_stdout
      end
    end
  end
end
