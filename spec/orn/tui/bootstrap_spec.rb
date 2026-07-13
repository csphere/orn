# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Bootstrap do
      def project_app
        App.new(output_mode: Orn::OutputMode.quiet, root: "/tmp/nonexistent", session: "test", base_branch: "main")
      end

      def global_app
        GlobalApp.new(
          output_mode: Orn::OutputMode.quiet,
          config: Orn::Config::GlobalTuiConfig.new(session: "orn", scan_roots: [], scan_depth: 3)
        )
      end

      def char(character)
        KeyEvent.char(character)
      end

      describe ".dispatch_project" do
        it "signals quit on q in normal mode" do
          expect(described_class.dispatch_project(project_app, char("q"))).to eq(:quit)
        end

        it "enters new-branch mode on n" do
          app = project_app
          described_class.dispatch_project(app, char("n"))

          expect(app.mode).to eq(Mode.new_branch(""))
        end

        it "accumulates typed characters while in new-branch mode" do
          app = project_app
          app.start_new_branch
          described_class.dispatch_project(app, char("x"))

          expect(app.mode).to eq(Mode.new_branch("x"))
        end

        it "cancels new-branch mode on escape" do
          app = project_app
          app.start_new_branch
          described_class.dispatch_project(app, KeyEvent.key(:esc))

          expect(app.mode).to eq(Mode.normal)
        end

        it "cancels a remove confirmation on any key but y" do
          app = project_app
          app.instance_variable_set(:@mode, Mode.confirm_remove("feat"))
          described_class.dispatch_project(app, char("n"))

          expect(app.mode).to eq(Mode.normal)
        end

        it "clears a pending error on any key press" do
          app = project_app
          app.error = "boom"
          described_class.dispatch_project(app, char("k"))

          expect(app.error).to be_nil
        end
      end

      describe ".dispatch_global" do
        it "signals quit on q" do
          expect(described_class.dispatch_global(global_app, char("q"))).to eq(:quit)
        end

        it "toggles expansion on space" do
          app = global_app
          app.entries = [RepoEntry.new(display_name: "a", root: "/tmp/x", healthy: true,
            session_name: "a", base_branch: "main", worktrees: [])]
          app.sync_list_state
          described_class.dispatch_global(app, char(" "))

          expect(app.entries[0].expanded).to be(true)
        end

        it "does not quit on other keys" do
          expect(described_class.dispatch_global(global_app, char("r"))).to be_nil
        end
      end

      describe ".run_loop" do
        it "draws and returns when quit is pressed" do
          backend = TestBackend.new(40, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)

          described_class.run_loop(terminal, project_app)

          expect(backend.buffer.to_s).to include("orn")
        end
      end

      describe ".run_global_loop" do
        it "draws and returns when quit is pressed" do
          backend = TestBackend.new(40, 8)
          backend.feed(char("q"))
          terminal = Terminal.new(backend)

          described_class.run_global_loop(terminal, global_app)

          expect(backend.buffer.to_s).to include("No orn repos found")
        end
      end
    end
  end
end
