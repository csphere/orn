# frozen_string_literal: true

RSpec.describe Orn::Commands::Remove do
  def project_with_worktree(branch)
    remote = make_remote_with_branch(branch)
    project = make_bare_project
    add_origin(project, remote)
    File.write(File.join(project, ".orn", "config.yaml"), "git:\n  base: main\n")
    worktree = Orn::Git::Worktree.new(root: project, output_mode: Orn::OutputMode.quiet)
    worktree.fetch("origin", branch)
    worktree.add(File.join(project, branch), branch, "origin/#{branch}")
    project
  end

  def load_project(root)
    Orn::Git::Project.new(root: root, config: Orn::Config.load_from(root, nil))
  end

  context "with a real tmux server", if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    it "closes the tmux window and removes the worktree" do
      project = project_with_worktree("feature/gone")

      Dir.chdir(project) do
        Orn::Tmux.open_window(Orn::OutputMode.quiet, load_project(project), "feature/gone")
        described_class.new(output_mode: Orn::OutputMode.quiet).run(["feature/gone"], prune: false, force: false)
      end

      session = Orn::Session.session_name(load_project(project))
      aggregate_failures do
        expect(File).not_to exist(File.join(project, "feature/gone"))
        expect(Orn::Tmux.window_exists?(Orn::OutputMode.quiet, session, "feature/gone")).to be(false)
      end
    end

    it "reports window_closed false when there is no window" do
      project = project_with_worktree("feature/nowin")
      command = described_class.new(output_mode: Orn::OutputMode.quiet)

      expect { Dir.chdir(project) { command.run(["feature/nowin"], prune: false, force: false) } }
        .to output(/"window_closed": false/).to_stdout
    end
  end
end
