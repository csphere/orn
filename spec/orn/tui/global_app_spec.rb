# frozen_string_literal: true

require "tmpdir"

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
        entry(name).with(
          expanded: expanded,
          worktrees: branches.map { |branch| WorktreeRow.new(branch: branch) }
        )
      end

      def global_config
        Orn::Config::GlobalTuiConfig.new(
          session: "orn",
          scan_roots: [],
          scan_depth: 3
        )
      end

      def app_with(entries, tabs: nil, mru_state: nil)
        described_class.new(
          output_mode: Orn::OutputMode.quiet,
          config: global_config,
          entries: entries,
          mru_state: mru_state,
          tabs: tabs
        )
      end

      def tabs_with_hub(hub, hub_pane: "%0", hub_location: %w[orn orn])
        Tabs.new(
          output_mode: Orn::OutputMode.quiet,
          hub_pane: hub_pane,
          hub_location: hub_location,
          hub: hub
        )
      end

      def fake_tabs
        tabs_with_hub(FakeHub.new)
      end

      def select_row(app, index)
        app.selected = index
        app.sync_list_state
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def all_panes_argv
        pane_format = "\#{session_name}\t\#{window_name}\t\#{pane_pid}\t" \
          "\#{pane_current_command}\t\#{pane_id}\t\#{pane_title}"
        ["tmux", "list-panes", "-a", "-F", pane_format]
      end

      def list_sessions_argv
        ["tmux", "list-sessions", "-F", "\#{session_name}\t\#{session_activity}"]
      end

      def has_session_argv(session)
        ["tmux", "has-session", "-t", session]
      end

      def list_windows_argv(session)
        ["tmux", "list-windows", "-t", "#{session}:", "-F", "\#{window_name}"]
      end

      def open_tab_for(tabs, repo, branch)
        tabs.open(
          root: repo.root,
          session: repo.session_name,
          base_branch: repo.base_branch,
          branch: branch
        )
      end

      def agent_repo(name, state)
        entry(name).with(aggregate_agent_state: state)
      end

      describe ".build" do
        def build_app
          described_class.build(
            Orn::OutputMode.quiet,
            global_config
          )
        end

        def hub_window_argv(pane)
          ["tmux", "display-message", "-p", "-t", pane, "\#{session_name}\t\#{window_name}"]
        end

        it "captures the hosting pane and its window for hub tabs" do
          ENV["XDG_STATE_HOME"] = register_temp_dir(Dir.mktmpdir("orn-state"))
          ENV["TMUX_PANE"] = "%3"
          with_fake_cmd do |fake|
            fake.script(hub_window_argv("%3"), stdout: "orn\thub\n")
            fake.script(all_panes_argv, status: 1)

            app = build_app

            aggregate_failures do
              expect(app.tabs.hub_pane).to eq("%3")
              expect(app.tabs.hub_location).to eq(%w[orn hub])
            end
          end
        end

        it "builds without hub tabs when running outside tmux" do
          ENV["XDG_STATE_HOME"] = register_temp_dir(Dir.mktmpdir("orn-state"))
          ENV.delete("TMUX_PANE")
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, status: 1)

            app = build_app

            aggregate_failures do
              expect(app.tabs.hub_pane).to be_nil
              expect(app.tabs.hub_location).to be_nil
            end
          end
        end
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

        it "loads git stats for the worktrees on expand and persists the state" do
          state = State.new
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            false
          )
          app = app_with([repo], mru_state: state)
          worktree_path = "/tmp/nonexistent-a/feat"
          with_fake_cmd do |fake|
            fake.script(["git", "-C", worktree_path, "status", "--porcelain"], stdout: " M f.txt\n")
            fake.script(
              ["git", "-C", worktree_path, "rev-list", "--left-right", "--count", "feat...main"],
              stdout: "2\t1\n"
            )

            app.toggle_expanded

            aggregate_failures do
              expect(app.entries[0].worktrees[0].dirty).to be(true)
              expect(app.entries[0].worktrees[0].ahead_behind).to eq([2, 1])
              expect(state.expanded?(repo.root)).to be(true)
            end
          end
        end

        it "collapses from the repo row itself, keeping the selection" do
          app = app_with(
            [
              entry_with_worktrees(
                "a",
                %w[main],
                true
              )
            ]
          )

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
          app.entries[0] = app.entries[0].with(expanded: false)

          app.move_down

          expect(app.selected).to be < app.visible_rows.length
        end
      end

      describe "#select_visible_tab_row" do
        it "moves the selection onto the visible tab's worktree row" do
          tabs = fake_tabs
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
            ],
            tabs: tabs
          )
          open_tab_for(tabs, app.entries[1], "main")

          app.select_visible_tab_row

          expect(app.selected_row).to eq(TreeRow.worktree(1, 0))
        end

        it "expands a collapsed owning repo" do
          tabs = fake_tabs
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
            ],
            tabs: tabs
          )
          open_tab_for(tabs, app.entries[1], "feat")

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

        it "keeps the selection when the tab's repo is not listed" do
          tabs = fake_tabs
          app = app_with([entry("a")], tabs: tabs)
          open_tab_for(tabs, entry("other"), "feat")

          app.select_visible_tab_row

          expect(app.selected).to eq(0)
        end

        it "keeps the selection when the tab's branch has no row" do
          tabs = fake_tabs
          repo = entry_with_worktrees(
            "a",
            %w[main],
            true
          )
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "gone")

          app.select_visible_tab_row

          expect(app.selected).to eq(0)
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

      describe "#maybe_refresh" do
        # The refresh cadence is tracked against a monotonic clock with no
        # injection seam, so these examples rewind the recorded refresh time
        # to make the next poll due.
        def make_tmux_refresh_due(app)
          app.instance_variable_set(:@last_tmux_refresh, monotonic_now - 10)
        end

        # An app with one collapsed repo, its "feat" tab open, and the tmux
        # refresh due.
        def due_app_with_open_tab(tabs)
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            false
          )
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          make_tmux_refresh_due(app)
          app
        end

        it "keeps tabs and stamps the refresh time when the pane listing fails" do
          app = due_app_with_open_tab(fake_tabs)
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, status: 1)

            app.maybe_refresh
            app.maybe_refresh

            aggregate_failures do
              expect(app.tabs.visible.branch).to eq("feat")
              # One listing only: the failed refresh still stamped the time,
              # so the second poll is not due yet.
              expect(fake.invocations).to eq([all_panes_argv])
            end
          end
        end

        it "runs a full discovery when the discovery refresh is due" do
          app = app_with([entry("a")])
          app.instance_variable_set(:@last_discovery, monotonic_now - 60)
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, status: 1)

            app.maybe_refresh

            # No scan roots are configured, so rediscovery replaces the stale
            # entries with an empty list.
            expect(app.entries).to be_empty
          end
        end

        it "prunes tabs whose panes are gone on a successful pane listing" do
          hub = FakeHub.new
          app = due_app_with_open_tab(tabs_with_hub(hub))
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, stdout: "")
            fake.script(list_sessions_argv, status: 1)

            app.maybe_refresh

            aggregate_failures do
              expect(app.tabs.visible).to be_nil
              expect(hub.count(:remove_bindings)).to eq(1)
              expect(app.entries[0].session_alive).to be(false)
            end
          end
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
          unhealthy = entry("broken").with(healthy: false)
          app = app_with([unhealthy])

          app.enter_selected

          expect(app.error).to be_nil
        end

        def app_on_worktree_row(repo, tabs:, mru_state: nil)
          app = app_with(
            [repo],
            tabs: tabs,
            mru_state: mru_state
          )
          select_row(app, 1)
          app
        end

        it "skips a worktree of an unhealthy repo" do
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          ).with(healthy: false)
          app = app_on_worktree_row(repo, tabs: tabs_with_hub(FakeHub.new, hub_pane: nil))

          app.enter_selected

          expect(app.error).to be_nil
        end

        it "records an error when the TUI runs outside tmux" do
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          tabs = tabs_with_hub(
            FakeHub.new,
            hub_pane: nil,
            hub_location: nil
          )
          app = app_on_worktree_row(repo, tabs: tabs)

          app.enter_selected

          expect(app.error).to eq("agent tabs require the TUI to run inside tmux")
        end

        it "opens a new tab and records the repo in the MRU state" do
          hub = FakeHub.new
          state = State.new
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          app = app_on_worktree_row(
            repo,
            tabs: tabs_with_hub(hub),
            mru_state: state
          )
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, status: 1)

            app.enter_selected

            aggregate_failures do
              expect(app.tabs.visible.branch).to eq("feat")
              expect(hub.calls).to include([:open_tab, ["feat", "%0"]])
              expect(state.timestamp(repo.root)).not_to be_nil
            end
          end
        end

        it "brings an open but hidden tab to front" do
          hub = FakeHub.new
          tabs = tabs_with_hub(hub)
          repo = entry_with_worktrees(
            "a",
            %w[feat main],
            true
          )
          app = app_on_worktree_row(repo, tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          open_tab_for(tabs, repo, "main")
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, status: 1)

            app.enter_selected

            aggregate_failures do
              expect(app.tabs.visible.branch).to eq("feat")
              expect(hub.calls).to include([:show_tab, "feat"])
            end
          end
        end

        it "drops a hidden tab whose pane cannot be shown, without refreshing" do
          hub = FakeHub.new(fail_on: [:show_tab])
          tabs = tabs_with_hub(hub)
          repo = entry_with_worktrees(
            "a",
            %w[feat main],
            true
          )
          app = app_on_worktree_row(repo, tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          open_tab_for(tabs, repo, "main")
          with_fake_cmd do |fake|
            app.enter_selected

            aggregate_failures do
              expect(app.tabs.visible).to be_nil
              expect(app.tabs.tab_index_for(repo.root, "feat")).to be_nil
              expect(fake.invocations).to be_empty
            end
          end
        end

        it "focuses the visible tab's agent pane" do
          tabs = fake_tabs
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          app = app_on_worktree_row(repo, tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          with_fake_cmd do |fake|
            fake.script(["tmux", "select-pane", "-t", "%1"])

            app.enter_selected

            expect(fake.invocations).to eq([["tmux", "select-pane", "-t", "%1"]])
          end
        end

        it "suppresses a failing pane focus" do
          tabs = fake_tabs
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          app = app_on_worktree_row(repo, tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          with_fake_cmd do |fake|
            fake.script(
              ["tmux", "select-pane", "-t", "%1"],
              stderr: "no such pane",
              status: 1
            )

            app.enter_selected

            expect(app.error).to be_nil
          end
        end

        it "reports a tab-open failure onto the error line through the default tabs" do
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          app = described_class.new(
            output_mode: Orn::OutputMode.quiet,
            config: global_config,
            entries: [repo],
            hub_pane: "%0",
            hub_location: %w[orn orn]
          )
          select_row(app, 1)
          pane_format = "\#{window_name}\t\#{pane_pid}\t\#{pane_current_command}\t\#{pane_id}\t\#{pane_title}"
          with_fake_cmd do |fake|
            fake.script(list_windows_argv("nonexistent"), stdout: "feat\n")
            fake.script(
              ["tmux", "list-panes", "-s", "-t", "nonexistent:", "-F", pane_format],
              stdout: ""
            )

            app.enter_selected

            expect(app.error).to eq("no pane found for 'feat' in session 'nonexistent'")
          end
        end

        it "records the repo row in the MRU state and reports a tmux failure" do
          isolate_global_config
          root = make_bare_project
          state = State.new
          app = app_with(
            [entry("a").with(root: root)],
            mru_state: state
          )
          session = File.basename(root)
          with_fake_cmd do |fake|
            fake.script(has_session_argv(session), status: 1)
            fake.script(
              ["tmux", "new-session", "-d", "-s", session, "-n", "main", "-c", root],
              stderr: "no server",
              status: 1
            )

            app.enter_selected

            aggregate_failures do
              expect(app.error).to eq("tmux failed: no server")
              expect(state.timestamp(root)).not_to be_nil
            end
          end
        end
      end

      describe "#poll_focus" do
        def active_pane_argv
          ["tmux", "list-panes", "-t", "orn:orn", "-F", "\#{pane_id}\t\#{?pane_active,1,0}"]
        end

        # The focus poll is rate-limited against a monotonic clock with no
        # injection seam, so these examples rewrite the recorded poll time to
        # place the next poll inside or past the interval.
        def record_last_focus_poll(app, time)
          app.instance_variable_set(:@last_focus_poll, time)
        end

        def app_with_visible_tab
          tabs = fake_tabs
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          app
        end

        it "clears the focus flag when no tab is visible" do
          app = app_with([])
          app.tabs.agent_focused = true

          app.poll_focus

          expect(app.tabs.agent_focused).to be(false)
        end

        it "skips the tmux query when polled again within the interval" do
          app = app_with_visible_tab
          app.tabs.agent_focused = true
          record_last_focus_poll(app, monotonic_now)
          with_fake_cmd do |_fake|
            app.poll_focus

            expect(app.tabs.agent_focused).to be(true)
          end
        end

        it "marks the agent focused once the interval has passed, then rate limits" do
          app = app_with_visible_tab
          record_last_focus_poll(app, monotonic_now - 1)
          with_fake_cmd do |fake|
            fake.script(active_pane_argv, stdout: "%0\t0\n%1\t1\n")

            app.poll_focus
            app.poll_focus

            aggregate_failures do
              expect(app.tabs.agent_focused).to be(true)
              expect(fake.invocations).to eq([active_pane_argv])
            end
          end
        end

        it "clears the flag when another pane is active" do
          app = app_with_visible_tab
          app.tabs.agent_focused = true
          record_last_focus_poll(app, monotonic_now - 1)
          with_fake_cmd do |fake|
            fake.script(active_pane_argv, stdout: "%0\t1\n%1\t0\n")

            app.poll_focus

            expect(app.tabs.agent_focused).to be(false)
          end
        end
      end

      describe "#enforce_layout" do
        def resize_argv
          ["tmux", "resize-pane", "-t", "%0", "-x", "33%"]
        end

        def app_with_visible_tab(tabs)
          repo = entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          app
        end

        it "re-applies the sidebar width while a tab is visible" do
          app = app_with_visible_tab(fake_tabs)
          with_fake_cmd do |fake|
            fake.script(resize_argv)

            app.enforce_layout

            expect(fake.invocations).to eq([resize_argv])
          end
        end

        it "does nothing without a visible tab" do
          app = app_with([entry("a")], tabs: fake_tabs)
          with_fake_cmd do |fake|
            app.enforce_layout

            expect(fake.invocations).to be_empty
          end
        end

        it "suppresses a failing resize" do
          app = app_with_visible_tab(fake_tabs)
          with_fake_cmd do |fake|
            fake.script(
              resize_argv,
              stderr: "no such pane",
              status: 1
            )

            expect { app.enforce_layout }.not_to raise_error
          end
        end
      end

      describe "#cycle_tab" do
        it "shows the next tab and follows it with the selection" do
          tabs = fake_tabs
          repo = entry_with_worktrees(
            "a",
            %w[feat main],
            true
          )
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          open_tab_for(tabs, repo, "main")
          with_fake_cmd do |fake|
            fake.script(all_panes_argv, status: 1)

            app.cycle_tab(true)

            aggregate_failures do
              expect(app.tabs.visible.branch).to eq("feat")
              expect(app.selected_row).to eq(TreeRow.worktree(0, 0))
            end
          end
        end

        it "is a no-op with no open tabs" do
          app = app_with([entry("a")], tabs: fake_tabs)
          with_fake_cmd do |fake|
            app.cycle_tab(true)

            aggregate_failures do
              expect(fake.invocations).to be_empty
              expect(app.selected).to eq(0)
            end
          end
        end
      end

      describe "#close_tab" do
        def repo_with_feat
          entry_with_worktrees(
            "a",
            %w[feat],
            true
          )
        end

        it "closes the selected worktree row's tab" do
          hub = FakeHub.new
          tabs = tabs_with_hub(hub)
          repo = repo_with_feat
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          select_row(app, 1)

          app.close_tab

          aggregate_failures do
            expect(app.tabs.visible).to be_nil
            expect(app.tabs.tab_index_for(repo.root, "feat")).to be_nil
            expect(hub.calls).to include([:hide_tab, "feat"], [:remove_bindings, nil])
          end
        end

        it "closes the visible tab when the selected row has none" do
          tabs = fake_tabs
          repo = repo_with_feat
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          select_row(app, 0)

          app.close_tab

          expect(app.tabs.visible).to be_nil
        end

        it "is a no-op with no tab to close" do
          hub = FakeHub.new
          app = app_with([entry("a")], tabs: tabs_with_hub(hub))

          app.close_tab

          expect(hub.calls).to be_empty
        end

        it "is a no-op on an empty list" do
          hub = FakeHub.new
          app = app_with([], tabs: tabs_with_hub(hub))

          app.close_tab

          expect(hub.calls).to be_empty
        end
      end

      describe "#close_all_tabs" do
        it "hides and forgets every tab" do
          hub = FakeHub.new
          tabs = tabs_with_hub(hub)
          repo = entry_with_worktrees(
            "a",
            %w[feat main],
            true
          )
          app = app_with([repo], tabs: tabs)
          open_tab_for(tabs, repo, "feat")
          open_tab_for(tabs, repo, "main")

          app.close_all_tabs

          aggregate_failures do
            expect(app.tabs.visible).to be_nil
            expect(app.tabs.tab_index_for(repo.root, "feat")).to be_nil
            expect(app.tabs.tab_index_for(repo.root, "main")).to be_nil
            expect(hub.count(:remove_bindings)).to eq(1)
          end
        end
      end

      describe ".enter_repo" do
        def switch_client_argv(session)
          ["tmux", "switch-client", "-t", "#{session}:orn"]
        end

        def new_window_argv(session, root)
          [
            "tmux",
            "new-window",
            "-a",
            "-t",
            "#{session}:",
            "-n",
            "orn",
            "-c",
            root,
            Orn::TUI.relaunch_command
          ]
        end

        it "creates the session and its TUI window, then switches the client" do
          isolate_global_config
          root = make_bare_project
          session = File.basename(root)
          new_session_argv = ["tmux", "new-session", "-d", "-s", session, "-n", "main", "-c", root]
          with_fake_cmd do |fake|
            fake.script(has_session_argv(session), status: 1)
            fake.script(new_session_argv)
            fake.script(list_windows_argv(session), stdout: "main\n")
            fake.script(new_window_argv(session, root))
            fake.script(switch_client_argv(session))

            described_class.enter_repo(Orn::OutputMode.quiet, root)

            expect(fake.invocations).to eq(
              [
                has_session_argv(session),
                new_session_argv,
                list_windows_argv(session),
                new_window_argv(session, root),
                list_windows_argv(session),
                switch_client_argv(session)
              ]
            )
          end
        end

        it "reuses an existing session and TUI window" do
          isolate_global_config
          root = make_bare_project
          session = File.basename(root)
          with_fake_cmd do |fake|
            fake.script(has_session_argv(session))
            fake.script(list_windows_argv(session), stdout: "orn\nmain\n")
            fake.script(switch_client_argv(session))

            described_class.enter_repo(Orn::OutputMode.quiet, root)

            expect(fake.invocations).to eq(
              [
                has_session_argv(session),
                list_windows_argv(session),
                list_windows_argv(session),
                switch_client_argv(session)
              ]
            )
          end
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
