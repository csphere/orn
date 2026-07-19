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

      def app_with(entries, tabs: nil)
        app = GlobalApp.new(
          output_mode: Orn::OutputMode.quiet,
          config: Orn::Config::GlobalTuiConfig.new(
            session: "orn",
            scan_roots: [],
            scan_depth: 3
          ),
          entries: entries,
          tabs: tabs
        )
        app.sync_list_state
        app
      end

      def tabs_with_fake_hub
        Tabs.new(
          output_mode: Orn::OutputMode.quiet,
          hub_pane: "%0",
          hub_location: %w[orn orn],
          hub: FakeHub.new
        )
      end

      def open_tab_for(tabs, repo, branch)
        tabs.open(
          root: repo.root,
          session: repo.session_name,
          base_branch: repo.base_branch,
          branch: branch
        )
      end

      def render(app, width: 60, height: 10)
        Terminal.new(TestBackend.new(width, height)).draw { |frame| described_class.draw(frame, app) }
      end

      def row_text(buffer, row_y)
        (0...buffer.area.width).map { |x| buffer[[x, row_y]].symbol }.join
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
          expect(screen).not_to include("r:refresh")
        end
      end

      it "highlights the selected row with a white background" do
        app = app_with([entry("alpha"), entry("beta")])
        app.selected = 1
        app.sync_list_state

        expect(render(app)[[1, 3]].bg).to eq(Color::WHITE)
      end

      it "grays out an unhealthy repo" do
        broken = entry("broken").with(healthy: false)

        expect(render(app_with([broken]))[[1, 2]].fg).to eq(Color::DARK_GRAY)
      end

      it "renders session and worktree count columns" do
        repo = entry("seaseducation/api").with(
          session_alive: true,
          window_count: 3,
          worktrees: Array.new(5) { |i| WorktreeRow.new(branch: "wt-#{i}") }
        )

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
          repo = entry("seaseducation/api").with(
            session_alive: true,
            aggregate_agent_state: state
          )
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

      describe "error line" do
        it "renders the error in red between the tree and the help footer" do
          app = app_with([entry("api")])
          app.error = "tmux failed: no server"

          # Layout for height 10: title rows 0-1, tree 2-6, error 7, help 8-9.
          buffer = render(app, height: 10)

          aggregate_failures do
            expect(row_text(buffer, 7)).to include("tmux failed: no server")
            expect(buffer[[1, 7]].fg).to eq(Color::RED)
          end
        end
      end

      describe "worktree rows" do
        def expanded_repo(worktree)
          entry("api").with(
            expanded: true,
            worktrees: [worktree]
          )
        end

        def full_worktree
          WorktreeRow.new(
            branch: "feat",
            has_window: true,
            agent: Orn::Detect::PaneAgentState.new(
              agent: "claude",
              state: :idle
            ),
            sandboxed: true,
            dirty: true,
            ahead_behind: [2, 1]
          )
        end

        # An app with the full worktree's tab open and focused, and its row
        # selected.
        def app_with_focused_feat_tab
          tabs = tabs_with_fake_hub
          repo = expanded_repo(full_worktree)
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          tabs.agent_focused = true
          app.selected = 1
          app.sync_list_state
          app
        end

        it "renders every column when everything is on" do
          line = row_text(render(app_with_focused_feat_tab, width: 80), 3)

          aggregate_failures do
            expect(line).to include("\u{2503}")            # heavy bar: visible tab
            expect(line).to include("feat")
            expect(line).to include("\u{270e}")            # pencil: dirty
            expect(line).to include("\u{25cf}")            # filled circle: window open
            expect(line).to include("2\u{2191} 1\u{2193}") # ahead/behind counts
            expect(line).to include("\u{2b1a}")            # sandbox badge
            expect(line).to include("idle")                # agent label
          end
        end

        it "colors the sandbox badge cyan and the agent green on an unselected row" do
          repo = expanded_repo(full_worktree)
          buffer = render(app_with([repo], tabs: tabs_with_fake_hub), width: 80)
          badge_x = (0...80).find { |x| buffer[[x, 3]].symbol == "\u{2b1a}" }
          agent_x = (0...80).find { |x| buffer[[x, 3]].symbol == "\u{25cb}" }

          aggregate_failures do
            expect(buffer[[badge_x, 3]].fg).to eq(Color::CYAN)
            expect(buffer[[agent_x, 3]].fg).to eq(Color::GREEN)
          end
        end

        it "renders a bare worktree with empty indicators" do
          repo = expanded_repo(WorktreeRow.new(branch: "feat"))

          line = row_text(render(app_with([repo]), width: 80), 3)

          aggregate_failures do
            expect(line).to include("feat")
            expect(line).to include("\u{25cb}")     # empty circle: no window
            expect(line).not_to include("\u{2191}") # no ahead/behind before stats load
            expect(line).not_to include("\u{2b1a}")
          end
        end
      end

      describe "tab gutter states" do
        def repo_with_feat
          entry("api").with(
            expanded: true,
            worktrees: [WorktreeRow.new(branch: "feat")]
          )
        end

        def gutter_for(app, repo)
          described_class.tab_gutter(
            app,
            repo,
            repo.worktrees[0],
            Style.default
          )
        end

        it "marks the visible tab with a heavy yellow bar while the agent pane has focus" do
          tabs = tabs_with_fake_hub
          repo = repo_with_feat
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          tabs.agent_focused = true

          expect(gutter_for(app, repo)).to eq(["\u{2503}", Style.default.fg(Color::YELLOW).bold])
        end

        it "marks the visible tab with a heavy white bar while the sidebar has focus" do
          tabs = tabs_with_fake_hub
          repo = repo_with_feat
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")

          expect(gutter_for(app, repo)).to eq(["\u{2503}", Style.default.fg(Color::WHITE).bold])
        end

        it "marks an open but hidden tab with a light gray bar" do
          tabs = tabs_with_fake_hub
          repo = repo_with_feat
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          tabs.hide_visible

          expect(gutter_for(app, repo)).to eq(["\u{2502}", Style.default.fg(Color::DARK_GRAY)])
        end

        it "leaves the gutter blank for a worktree without a tab" do
          repo = repo_with_feat
          app = app_with([repo], tabs: tabs_with_fake_hub)

          expect(gutter_for(app, repo)).to eq([" ", Style.default])
        end
      end

      describe "dirty indicator" do
        it "maps each dirty state to its glyph" do
          glyph_by_state = {
            true => "\u{270e}",
            false => "\u{2714}",
            nil => " "
          }

          aggregate_failures do
            glyph_by_state.each do |dirty, glyph|
              worktree = WorktreeRow.new(
                branch: "feat",
                dirty: dirty
              )
              expect(described_class.dirty_indicator(worktree)).to eq(glyph)
            end
          end
        end
      end
    end
  end
end
