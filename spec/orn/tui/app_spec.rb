# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe App do
      def build_app(branches)
        app = described_class.new(
          output_mode: Orn::OutputMode.quiet,
          root: "/tmp/nonexistent",
          session: "test",
          base_branch: "main"
        )
        app.entries = branches.map { |name| status(name) }
        app
      end

      def status(branch)
        WorktreeStatus.new(branch: branch, dirty: false, has_window: false, ahead: 0, behind: 0)
      end

      def working_state
        Orn::Detect::PaneAgentState.new(agent: :claude, state: :working)
      end

      describe "selection movement" do
        it "moves down, wrapping past the end" do
          app = build_app(%w[a b c])

          aggregate_failures do
            app.move_down
            expect(app.selected).to eq(1)
            app.move_down
            app.move_down
            expect(app.selected).to eq(0)
          end
        end

        it "moves up, wrapping past the start" do
          app = build_app(%w[a b c])

          aggregate_failures do
            app.move_up
            expect(app.selected).to eq(2)
            app.move_up
            expect(app.selected).to eq(1)
          end
        end

        it "does nothing on an empty list" do
          app = build_app([])

          aggregate_failures do
            app.move_down
            app.move_up
            expect(app.selected).to eq(0)
          end
        end

        it "stays put with a single item" do
          app = build_app(%w[only])

          app.move_down
          app.move_up
          expect(app.selected).to eq(0)
        end
      end

      describe "input modes" do
        it "enters new-branch mode with an empty input" do
          app = build_app([])
          app.start_new_branch

          expect(app.mode).to eq(Mode.new_branch(""))
        end

        it "accumulates and backspaces typed characters" do
          app = build_app([])
          app.start_new_branch
          app.new_branch_push_char("a")
          app.new_branch_push_char("b")
          app.new_branch_pop_char

          expect(app.mode).to eq(Mode.new_branch("a"))
        end

        it "enters confirm-remove mode for the selected branch" do
          app = build_app(%w[feature/x])
          app.start_remove

          expect(app.mode).to eq(Mode.confirm_remove("feature/x"))
        end

        it "does not enter confirm-remove on an empty list" do
          app = build_app([])
          app.start_remove

          expect(app.mode).to eq(Mode.normal)
        end

        it "returns to normal mode on cancel" do
          app = build_app([])
          app.start_new_branch
          app.cancel_mode

          expect(app.mode).to eq(Mode.normal)
        end

        it "returns to normal mode when confirming an empty branch name" do
          app = build_app([])
          app.start_new_branch
          app.confirm_new_branch

          expect(app.mode).to eq(Mode.normal)
        end
      end

      describe "agent state" do
        it "starts with no agent states" do
          expect(build_app(%w[main]).agent_states).to be_empty
        end

        it "reports an agent working" do
          app = build_app(%w[main])
          app.agent_states["main"] = working_state

          expect(app.any_agent_working?).to be(true)
        end

        it "does not report idle or blocked agents as working" do
          app = build_app(%w[main])
          app.agent_states["main"] = Orn::Detect::PaneAgentState.new(agent: :claude, state: :idle)

          expect(app.any_agent_working?).to be(false)
        end

        it "polls fast while an agent works and normally otherwise" do
          app = build_app(%w[main])

          aggregate_failures do
            expect(app.poll_timeout).to eq(POLL_TIMEOUT)
            app.agent_states["main"] = working_state
            expect(app.poll_timeout).to eq(FAST_POLL_TIMEOUT)
          end
        end
      end

      describe "errors" do
        it "clears an error" do
          app = build_app([])
          app.error = "oops"
          app.clear_error

          expect(app.error).to be_nil
        end
      end

      describe ".ahead_behind" do
        it "returns zeros for an invalid path" do
          counts = described_class.ahead_behind(Orn::OutputMode.quiet, "/tmp/nonexistent", "feature", "main")

          expect(counts).to eq([0, 0])
        end
      end

      describe "#confirm_new_branch", if: TmuxSpecSupport::AVAILABLE do
        include_context "with an isolated tmux server"

        def remote_backed_project(branch)
          remote = make_remote_with_branch(branch)
          root = make_bare_project
          add_origin(root, remote)
          File.write(File.join(root, ".orn", "config.yaml"), "git:\n  base: main\n")
          worktree = Orn::Git::Worktree.new(root: root, output_mode: Orn::OutputMode.quiet)
          worktree.fetch("origin", "main")
          worktree.add(File.join(root, "main"), "main", "origin/main")
          root
        end

        def app_for(root)
          described_class.new(
            output_mode: Orn::OutputMode.quiet,
            root: root,
            session: "orn-app-spec",
            base_branch: "main"
          )
        end

        it "creates a worktree tracking the remote branch when it exists" do
          root = remote_backed_project("feature/remote-only")
          app = app_for(root)
          app.mode = Mode.new_branch("feature/remote-only")

          app.confirm_new_branch

          expect(File).to exist(File.join(root, "feature/remote-only", "g.txt"))
        end

        it "creates a worktree off base when the branch is not on the remote" do
          root = remote_backed_project("feature/other")
          app = app_for(root)
          app.mode = Mode.new_branch("feature/brand-new")

          app.confirm_new_branch

          aggregate_failures do
            expect(File).to be_directory(File.join(root, "feature/brand-new"))
            expect(File).not_to exist(File.join(root, "feature/brand-new", "g.txt"))
          end
        end
      end
    end
  end
end
