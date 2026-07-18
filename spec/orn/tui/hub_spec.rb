# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Hub do
      def pane(id)
        Orn::Tmux::PaneMetadata.new(
          session_name: nil,
          window_name: "w",
          pane_pid: 1,
          pane_title: "",
          pane_current_command: "zsh",
          pane_id: id
        )
      end

      def tab(pane_id)
        described_class::Tab.new(
          root: "/tmp/repo",
          session: "repo",
          base_branch: "main",
          branch: "feat",
          pane_id: pane_id
        )
      end

      describe ".tab_pane_alive" do
        it "is true when the tab's pane is listed" do
          expect(described_class.tab_pane_alive(tab("%3"), [pane("%1"), pane("%3")])).to be(true)
        end

        it "is false when the tab's pane is missing" do
          expect(described_class.tab_pane_alive(tab("%3"), [pane("%1")])).to be(false)
        end
      end

      describe ".cycle_index" do
        it "wraps forward and backward from a visible tab" do
          aggregate_failures do
            expect(
              described_class.cycle_index(
                3,
                2,
                true
              )
            ).to eq(0)
            expect(
              described_class.cycle_index(
                3,
                0,
                false
              )
            ).to eq(2)
            expect(
              described_class.cycle_index(
                3,
                0,
                true
              )
            ).to eq(1)
          end
        end

        it "starts from the ends when no tab is visible" do
          aggregate_failures do
            expect(
              described_class.cycle_index(
                3,
                nil,
                true
              )
            ).to eq(0)
            expect(
              described_class.cycle_index(
                3,
                nil,
                false
              )
            ).to eq(2)
          end
        end

        it "is nil when there are no tabs" do
          expect(
            described_class.cycle_index(
              0,
              nil,
              true
            )
          ).to be_nil
        end
      end

      describe ".adjust_visible_after_remove" do
        it "drops the selection when the visible tab is removed" do
          expect(described_class.adjust_visible_after_remove(1, 1)).to be_nil
        end

        it "shifts the index down when an earlier tab is removed" do
          expect(described_class.adjust_visible_after_remove(2, 1)).to eq(1)
        end

        it "leaves an earlier visible tab untouched" do
          expect(described_class.adjust_visible_after_remove(0, 1)).to eq(0)
        end

        it "stays nil when nothing is visible" do
          expect(described_class.adjust_visible_after_remove(nil, 0)).to be_nil
        end
      end
    end
  end
end
