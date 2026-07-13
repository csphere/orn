# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe GlobalUi do
      def entry(name)
        RepoEntry.new(
          display_name: name,
          root: "/tmp/nonexistent-#{name}",
          healthy: true,
          session_name: "nonexistent",
          base_branch: "main"
        )
      end

      def app_with(entries)
        app = GlobalApp.new(
          output_mode: Orn::OutputMode.quiet,
          config: Orn::Config::GlobalTuiConfig.new(session: "orn", scan_roots: [], scan_depth: 3),
          entries: entries
        )
        app.sync_list_state
        app
      end

      def render(app, width: 60, height: 10)
        Terminal.new(TestBackend.new(width, height)).draw { |frame| described_class.draw(frame, app) }
      end

      it "renders without error on an empty list" do
        expect { render(app_with([])) }.not_to raise_error
      end

      it "renders repo names" do
        screen = render(app_with([entry("seaseducation/api"), entry("client/webapp")])).to_s

        aggregate_failures do
          expect(screen).to include("seaseducation/api")
          expect(screen).to include("client/webapp")
        end
      end

      it "shows an empty message when no repos are found" do
        expect(render(app_with([])).to_s).to include("No orn repos found")
      end

      it "renders the title" do
        expect(render(app_with([])).to_s).to include("orn")
      end

      it "renders the help footer" do
        screen = render(app_with([])).to_s

        aggregate_failures do
          expect(screen).to include("enter:open")
          expect(screen).to include("q:quit")
        end
      end

      it "highlights the selected row with a white background" do
        app = app_with([entry("alpha"), entry("beta")])
        app.selected = 1
        app.sync_list_state

        expect(render(app)[[1, 3]].bg).to eq(Color::WHITE)
      end

      it "grays out an unhealthy repo" do
        broken = entry("broken")
        broken.healthy = false

        expect(render(app_with([broken]))[[1, 2]].fg).to eq(Color::DARK_GRAY)
      end

      it "renders session and worktree count columns" do
        repo = entry("seaseducation/api")
        repo.session_alive = true
        repo.window_count = 3
        repo.worktrees = Array.new(5) { |i| WorktreeRow.new(branch: "wt-#{i}") }

        screen = render(app_with([repo]), width: 80).to_s

        aggregate_failures do
          expect(screen).to include("\u{25cf}")
          expect(screen).to include("3 active")
          expect(screen).to include("5 wt")
        end
      end

      it "shows an empty circle for an inactive session" do
        expect(render(app_with([entry("inactive")]), width: 80).to_s).to include("\u{25cb}")
      end

      it "scrolls so the selected repo stays visible" do
        entries = Array.new(20) { |i| entry(format("repo-%02d", i)) }
        app = app_with(entries)
        app.selected = 19
        app.sync_list_state

        expect(render(app, height: 8).to_s).to include("repo-19")
      end

      it "keeps the last row visible after moving down past the viewport" do
        entries = Array.new(10) { |i| entry(format("item-%02d", i)) }
        app = app_with(entries)
        9.times { app.move_down }

        aggregate_failures do
          expect(app.selected).to eq(9)
          expect(render(app, height: 8).to_s).to include("item-09")
        end
      end

      describe "aggregate agent indicators" do
        def agent_app(state)
          repo = entry("seaseducation/api")
          repo.session_alive = true
          repo.aggregate_agent_state = state
          app_with([repo])
        end

        it "labels a blocked aggregate" do
          expect(render(agent_app(:blocked), width: 80).to_s).to include("blocked")
        end

        it "labels a working aggregate" do
          expect(render(agent_app(:working), width: 80).to_s).to include("working")
        end

        it "shows no label without agents" do
          screen = render(app_with([entry("seaseducation/api")]), width: 80).to_s

          aggregate_failures do
            expect(screen).not_to include("blocked")
            expect(screen).not_to include("working")
            expect(screen).not_to include("idle")
          end
        end
      end
    end
  end
end
