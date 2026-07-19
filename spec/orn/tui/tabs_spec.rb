# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Tabs do
      attr_reader :hub,
        :errors

      before do
        @hub = FakeHub.new
        @errors = []
      end

      def build_tabs(hub_pane: "%0", hub_location: %w[orn orn])
        described_class.new(
          output_mode: Orn::OutputMode.quiet,
          hub_pane: hub_pane,
          hub_location: hub_location,
          hub: hub,
          on_error: ->(message) { errors << message }
        )
      end

      def open_tab(tabs, branch)
        tabs.open(
          root: "/tmp/repo",
          session: "repo",
          base_branch: "main",
          branch: branch
        )
      end

      def pane(id, session: "orn", window: "orn")
        Orn::Tmux::PaneMetadata.new(
          session_name: session,
          window_name: window,
          pane_pid: 1,
          pane_title: "",
          pane_current_command: "zsh",
          pane_id: id
        )
      end

      describe "#open" do
        it "opens a tab, makes it visible, and installs the bindings" do
          tabs = build_tabs

          opened = open_tab(tabs, "feat")

          aggregate_failures do
            expect(opened).to be(true)
            expect(tabs.visible.branch).to eq("feat")
            expect(tabs.visible_index).to eq(0)
            expect(hub.calls).to include([:install_bindings, "%1"])
          end
        end

        it "hides the previously visible tab" do
          tabs = build_tabs
          open_tab(tabs, "one")

          open_tab(tabs, "two")

          aggregate_failures do
            expect(hub.calls).to include([:hide_tab, "one"])
            expect(tabs.visible.branch).to eq("two")
            expect(tabs.tab_index_for("/tmp/repo", "one")).to eq(0)
          end
        end

        it "adds no tab when borrowing the pane fails" do
          hub.fail_on = [:open_tab]
          tabs = build_tabs

          opened = open_tab(tabs, "feat")

          aggregate_failures do
            expect(opened).to be(false)
            expect(errors).to eq(["open_tab failed"])
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to be_nil
          end
        end

        it "keeps the previous tab open but hidden after a failed open" do
          tabs = build_tabs
          open_tab(tabs, "one")
          hub.fail_on = [:open_tab]

          open_tab(tabs, "two")

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "one")).to eq(0)
          end
        end

        it "refuses to open without a hub pane" do
          tabs = build_tabs(hub_pane: nil)

          opened = open_tab(tabs, "feat")

          aggregate_failures do
            expect(opened).to be(false)
            expect(hub.calls).to be_empty
          end
        end
      end

      describe "#show" do
        it "hides the visible tab and brings the target to front" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")

          shown = tabs.show(0)

          aggregate_failures do
            expect(shown).to be(true)
            expect(tabs.visible.branch).to eq("one")
            expect(hub.calls).to include([:hide_tab, "two"])
            expect(hub.calls).to include([:show_tab, "one"])
            expect(hub.calls.last).to eq([:install_bindings, "%1"])
          end
        end

        it "drops a tab whose pane cannot be borrowed" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")
          hub.fail_on = [:show_tab]

          shown = tabs.show(0)

          aggregate_failures do
            expect(shown).to be(false)
            expect(errors).to eq(["show_tab failed"])
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "one")).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "two")).to eq(0)
          end
        end
      end

      describe "#hide_visible" do
        it "returns the visible pane home and keeps the tab open" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          tabs.hide_visible

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to eq(0)
            expect(hub.calls).to include([:hide_tab, "feat"])
          end
        end

        it "still demotes the tab when returning the pane fails" do
          tabs = build_tabs
          open_tab(tabs, "feat")
          hub.fail_on = [:hide_tab]

          tabs.hide_visible

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(errors).to eq(["hide_tab failed"])
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to eq(0)
          end
        end

        it "is a no-op with nothing visible" do
          tabs = build_tabs

          tabs.hide_visible

          expect(hub.count(:hide_tab)).to eq(0)
        end
      end

      describe "#close" do
        it "hides and removes the visible tab and tears down the bindings" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          tabs.close(0)

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to be_nil
            expect(hub.calls).to include([:hide_tab, "feat"])
            expect(hub.count(:remove_bindings)).to eq(1)
          end
        end

        it "shifts the visible index down when an earlier hidden tab closes" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")

          tabs.close(0)

          aggregate_failures do
            expect(tabs.visible.branch).to eq("two")
            expect(tabs.visible_index).to eq(0)
            expect(hub.count(:remove_bindings)).to eq(0)
          end
        end

        it "leaves the visible index alone when a later hidden tab closes" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")
          tabs.show(0)

          tabs.close(1)

          aggregate_failures do
            expect(tabs.visible.branch).to eq("one")
            expect(tabs.visible_index).to eq(0)
          end
        end
      end

      describe "#close_all" do
        it "hides the visible tab, forgets every tab, and tears down the bindings" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")

          tabs.close_all

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "one")).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "two")).to be_nil
            expect(hub.calls).to include([:hide_tab, "two"])
            expect(hub.count(:remove_bindings)).to eq(1)
          end
        end
      end

      describe "#cycle" do
        it "is a no-op with no tabs" do
          tabs = build_tabs

          aggregate_failures do
            expect(tabs.cycle(true)).to be(false)
            expect(hub.calls).to be_empty
          end
        end

        it "is a no-op when the only tab is already visible" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          expect(tabs.cycle(true)).to be(false)
        end

        it "starts from the ends when no tab is visible" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")
          tabs.hide_visible

          aggregate_failures do
            expect(tabs.cycle(true)).to be(true)
            expect(tabs.visible.branch).to eq("one")
            tabs.hide_visible
            expect(tabs.cycle(false)).to be(true)
            expect(tabs.visible.branch).to eq("two")
          end
        end

        it "wraps forward past the end" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")

          tabs.cycle(true)

          expect(tabs.visible.branch).to eq("one")
        end

        it "wraps backward past the start" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")
          tabs.show(0)

          tabs.cycle(false)

          expect(tabs.visible.branch).to eq("two")
        end
      end

      describe "#prune_dead_tabs" do
        it "drops tabs whose panes are gone and keeps the rest" do
          tabs = build_tabs
          open_tab(tabs, "one")
          open_tab(tabs, "two")

          tabs.prune_dead_tabs([pane("%2")])

          aggregate_failures do
            expect(tabs.tab_index_for("/tmp/repo", "one")).to be_nil
            expect(tabs.visible.branch).to eq("two")
            expect(tabs.visible_index).to eq(0)
            expect(hub.count(:remove_bindings)).to eq(0)
          end
        end

        it "tears down the bindings when the visible tab's pane died" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          tabs.prune_dead_tabs([])

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to be_nil
            expect(hub.count(:remove_bindings)).to eq(1)
          end
        end

        it "leaves the bindings alone when nothing was visible" do
          tabs = build_tabs
          open_tab(tabs, "feat")
          tabs.hide_visible

          tabs.prune_dead_tabs([])

          aggregate_failures do
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to be_nil
            expect(hub.count(:remove_bindings)).to eq(0)
          end
        end
      end

      describe "#demote_visible_if_moved" do
        it "demotes the visible tab when its pane left the hub window" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          tabs.demote_visible_if_moved(
            [
              pane(
                "%1",
                session: "repo",
                window: "feat"
              )
            ]
          )

          aggregate_failures do
            expect(tabs.visible).to be_nil
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to eq(0)
            expect(hub.count(:remove_bindings)).to eq(1)
          end
        end

        it "keeps the visible tab while its pane sits in the hub window" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          tabs.demote_visible_if_moved([pane("%1")])

          aggregate_failures do
            expect(tabs.visible.branch).to eq("feat")
            expect(hub.count(:remove_bindings)).to eq(0)
          end
        end
      end

      describe "#tab_index_for" do
        it "finds a tab by root and branch, else nil" do
          tabs = build_tabs
          open_tab(tabs, "feat")

          aggregate_failures do
            expect(tabs.tab_index_for("/tmp/repo", "feat")).to eq(0)
            expect(tabs.tab_index_for("/tmp/repo", "other")).to be_nil
            expect(tabs.tab_index_for("/tmp/elsewhere", "feat")).to be_nil
          end
        end
      end
    end
  end
end
