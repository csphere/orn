# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe GlobalApp do
      def entry(name)
        RepoEntry.new(
          display_name: name,
          root: "/tmp/nonexistent-#{name}",
          healthy: true,
          session_name: "nonexistent",
          base_branch: "main"
        )
      end

      def entry_with_worktrees(name, branches, expanded)
        row = entry(name)
        row.expanded = expanded
        row.worktrees = branches.map { |branch| WorktreeRow.new(branch: branch) }
        row
      end

      def app_with(entries)
        described_class.new(
          output_mode: Orn::OutputMode.quiet,
          config: Orn::Config::GlobalTuiConfig.new(
            session: "orn",
            scan_roots: [],
            scan_depth: 3
          ),
          entries: entries
        )
      end

      def tab_for(repo, branch)
        Hub::Tab.new(
          root: repo.root,
          session: repo.session_name,
          base_branch: repo.base_branch,
          branch: branch,
          pane_id: "%9"
        )
      end

      def agent_repo(name, state)
        row = entry(name)
        row.aggregate_agent_state = state
        row
      end

      describe "#visible_rows" do
        it "hides worktrees of collapsed repos" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main feat],
                false
              ),
              entry("b")
            ]
          )

          expect(app.visible_rows).to eq([TreeRow.repo(0), TreeRow.repo(1)])
        end

        it "shows worktrees of expanded repos" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main feat],
                true
              ),
              entry("b")
            ]
          )

          expect(app.visible_rows).to eq(
            [
              TreeRow.repo(0), TreeRow.worktree(0, 0), TreeRow.worktree(0, 1), TreeRow.repo(1)
            ]
          )
        end
      end

      describe "selection movement" do
        it "traverses expanded worktrees then wraps" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main],
                true
              ),
              entry("b")
            ]
          )

          aggregate_failures do
            app.move_down
            expect(app.selected_row).to eq(TreeRow.worktree(0, 0))
            app.move_down
            expect(app.selected_row).to eq(TreeRow.repo(1))
            app.move_down
            expect(app.selected_row).to eq(TreeRow.repo(0))
          end
        end

        it "wraps up and down over repos" do
          app = app_with([entry("a"), entry("b"), entry("c")])

          aggregate_failures do
            app.move_up
            expect(app.selected).to eq(2)
            app.move_down
            expect(app.selected).to eq(0)
          end
        end

        it "does nothing on an empty list" do
          app = app_with([])

          aggregate_failures do
            app.move_down
            app.move_up
            expect(app.selected).to eq(0)
          end
        end

        it "keeps the list state in sync with the selection" do
          app = app_with([entry("a"), entry("b"), entry("c")])

          aggregate_failures do
            expect(app.list_state.selected).to eq(0)
            app.move_down
            expect(app.list_state.selected).to eq(1)
          end
        end

        it "selects nothing on an empty list" do
          app = app_with([])

          aggregate_failures do
            expect(app.list_state.selected).to be_nil
            app.move_down
            expect(app.list_state.selected).to be_nil
          end
        end
      end

      describe "#toggle_expanded" do
        it "expands the selected repo" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main],
                false
              )
            ]
          )
          app.toggle_expanded

          aggregate_failures do
            expect(app.entries[0].expanded).to be(true)
            expect(app.visible_rows.length).to eq(2)
          end
        end

        it "collapses to the repo row from a worktree row" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main feat],
                true
              ),
              entry("b")
            ]
          )
          app.selected = 2

          app.toggle_expanded

          aggregate_failures do
            expect(app.entries[0].expanded).to be(false)
            expect(app.selected_row).to eq(TreeRow.repo(0))
          end
        end

        it "is a no-op on an empty list" do
          app = app_with([])
          app.toggle_expanded

          expect(app.visible_rows).to be_empty
        end

        it "keeps the selection in range after collapse" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main feat],
                true
              )
            ]
          )
          app.selected = 2
          app.entries[0].expanded = false

          app.move_down

          expect(app.selected).to be < app.visible_rows.length
        end
      end

      describe "#select_visible_tab_row" do
        it "moves the selection onto the visible tab's worktree row" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main feat],
                true
              ),
              entry_with_worktrees(
                "b",
                %w[main],
                true
              )
            ]
          )
          app.hub.visible_index = app.hub.push_tab(tab_for(app.entries[1], "main"))

          app.select_visible_tab_row

          expect(app.selected_row).to eq(TreeRow.worktree(1, 0))
        end

        it "expands a collapsed owning repo" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main],
                true
              ),
              entry_with_worktrees(
                "b",
                %w[main feat],
                false
              )
            ]
          )
          app.hub.visible_index = app.hub.push_tab(tab_for(app.entries[1], "feat"))

          app.select_visible_tab_row

          aggregate_failures do
            expect(app.entries[1].expanded).to be(true)
            expect(app.selected_row).to eq(TreeRow.worktree(1, 1))
          end
        end

        it "is a no-op without a visible tab" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main],
                true
              )
            ]
          )
          app.selected = 1
          app.sync_list_state

          app.select_visible_tab_row

          expect(app.selected_row).to eq(TreeRow.worktree(0, 0))
        end
      end

      describe "#reanchor_selected" do
        it "follows a repo across a resort" do
          app = app_with([entry("a"), entry("b"), entry("c")])
          app.selected = 1
          anchor = app.selected_identity
          app.entries.push(app.entries.shift) # rotate: b, c, a

          app.reanchor_selected(anchor)

          expect(app.entries[app.selected_row.repo_index].display_name).to eq("b")
        end

        it "follows a worktree across a resort" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main feat],
                true
              ),
              entry("b")
            ]
          )
          app.selected = 2
          anchor = app.selected_identity
          app.entries.push(app.entries.shift) # b now first

          app.reanchor_selected(anchor)

          expect(app.selected_row).to eq(TreeRow.worktree(1, 1))
        end

        it "clamps when the anchored row is gone" do
          app = app_with([entry("a"), entry("b"), entry("c")])
          app.selected = 2
          anchor = app.selected_identity
          app.entries = [entry("a"), entry("b")]

          app.reanchor_selected(anchor)

          expect(app.selected).to eq(1)
        end

        it "clamps when there is no anchor" do
          app = app_with([entry("a"), entry("b"), entry("c")])
          app.selected = 2
          app.entries = [entry("a")]

          app.reanchor_selected(nil)

          expect(app.selected).to eq(0)
        end
      end

      describe ".aggregate_state" do
        def states(*pairs)
          pairs.each_with_index.to_h do |(agent, state), i|
            [
              "win#{i}",
              Orn::Detect::PaneAgentState.new(
                agent: agent,
                state: state
              )
            ]
          end
        end

        it "ranks blocked over working" do
          expect(described_class.aggregate_state(states(%i[claude blocked], %i[claude working]))).to eq(:blocked)
        end

        it "ranks working over idle" do
          expect(described_class.aggregate_state(states(%i[claude working], %i[claude idle]))).to eq(:working)
        end

        it "returns idle when all agents are idle" do
          expect(described_class.aggregate_state(states(%i[claude idle], %i[claude idle]))).to eq(:idle)
        end

        it "returns nil when no pane hosts an agent" do
          expect(described_class.aggregate_state(states([nil, :unknown]))).to be_nil
        end

        it "returns nil for an empty set" do
          expect(described_class.aggregate_state({})).to be_nil
        end
      end

      describe "agent aggregate and polling" do
        it "reports working only when the aggregate is working" do
          aggregate_failures do
            expect(app_with([entry("repo")]).any_agent_working?).to be(false)
            expect(app_with([agent_repo("repo", :working)]).any_agent_working?).to be(true)
            expect(app_with([agent_repo("repo", :blocked)]).any_agent_working?).to be(false)
          end
        end

        it "polls fast while working and normally otherwise" do
          aggregate_failures do
            expect(app_with([agent_repo("repo", :working)]).poll_timeout).to eq(FAST_POLL_TIMEOUT)
            expect(app_with([entry("repo")]).poll_timeout).to eq(POLL_TIMEOUT)
          end
        end
      end

      describe "#enter_selected" do
        it "is a no-op on an empty list" do
          app = app_with([])
          app.enter_selected

          expect(app.error).to be_nil
        end

        it "skips an unhealthy repo" do
          unhealthy = entry("broken")
          unhealthy.healthy = false
          app = app_with([unhealthy])

          app.enter_selected

          expect(app.error).to be_nil
        end
      end

      describe "#clear_error" do
        it "removes the error" do
          app = app_with([])
          app.error = "oops"
          app.clear_error

          expect(app.error).to be_nil
        end
      end
    end
  end
end
