# frozen_string_literal: true

module Orn
  module TUI
    RSpec.describe Ui do
      def app_with(entries)
        app = App.new(
          output_mode: Orn::OutputMode.quiet,
          root: "/tmp/nonexistent",
          session: "test",
          base_branch: "main",
          repo_name: "test-repo"
        )
        app.entries = entries
        app
      end

      def entry(branch, dirty: false, has_window: false, ahead: 0, behind: 0)
        WorktreeStatus.new(
          branch: branch,
          dirty: dirty,
          has_window: has_window,
          ahead: ahead,
          behind: behind
        )
      end

      def render(app, width: 60, height: 12)
        Terminal.new(TestBackend.new(width, height)).draw { |frame| described_class.draw(frame, app) }
      end

      it "renders without error on an empty list" do
        expect { render(app_with([])) }.not_to raise_error
      end

      it "renders the branch name and repo title" do
        screen = render(app_with([entry("main", has_window: true)])).to_s

        aggregate_failures do
          expect(screen).to include("orn")
          expect(screen).to include("test-repo")
          expect(screen).to include("main")
        end
      end

      it "shows a pencil for a dirty branch and a checkmark for a clean one" do
        aggregate_failures do
          expect(render(app_with([entry("dev", dirty: true)])).to_s).to include("\u{270e}")
          expect(render(app_with([entry("main")])).to_s).to include("\u{2714}")
        end
      end

      it "shows ahead and behind counts" do
        screen = render(
          app_with(
            [
              entry(
                "dev",
                ahead: 5,
                behind: 2
              )
            ]
          )
        ).to_s

        aggregate_failures do
          expect(screen).to include("5")
          expect(screen).to include("2")
        end
      end

      it "renders the mode-specific help line" do
        screen = render(app_with([])).to_s

        aggregate_failures do
          expect(screen).to include("enter:open")
          expect(screen).to include("n:new")
          expect(screen).to include("q:quit")
          expect(screen).not_to include("r:refresh")
        end
      end

      it "highlights the selected row with a white background" do
        app = app_with([entry("main", has_window: true), entry("dev", dirty: true)])
        app.selected = 1

        buffer = render(app)

        expect(buffer[[1, 3]].bg).to eq(Color::WHITE)
      end

      it "renders an error line in red at height minus three" do
        app = app_with([entry("main")])
        app.error = "something went wrong"

        buffer = render(app)

        aggregate_failures do
          expect(buffer.to_s).to include("something went wrong")
          expect(buffer[[1, buffer.area.height - 3]].fg).to eq(Color::RED)
        end
      end

      it "omits the error row when there is no error" do
        expect(render(app_with([]))).to be_a(Buffer)
      end

      it "renders the new-branch modal with the typed input" do
        app = app_with([])
        app.mode = Mode.new_branch("feature/foo")

        screen = render(app).to_s

        aggregate_failures do
          expect(screen).to include("Branch:")
          expect(screen).to include("feature/foo")
          expect(screen).to include("esc:cancel")
        end
      end

      it "renders the confirm-remove modal" do
        app = app_with([entry("old-branch")])
        app.mode = Mode.confirm_remove("old-branch")

        screen = render(app).to_s

        aggregate_failures do
          expect(screen).to include("Remove old-branch?")
          expect(screen).to include("y:confirm")
        end
      end

      describe "column sizing" do
        def row_text(buffer, row_y)
          (0...buffer.area.width).map { |x| buffer[[x, row_y]].symbol }.join
        end

        it "shrinks the branch column to the floor for short names" do
          buffer = render(app_with([entry("main"), entry("fix/tui")]))

          expect(row_text(buffer, 2)).to start_with(" main       \u{2714}")
        end

        it "stretches the branch column to the widest branch" do
          buffer = render(app_with([entry("main"), entry("feature/wider")]))

          expect(row_text(buffer, 2)).to start_with(" main          \u{2714}")
        end

        it "renders a branch at the cap in full" do
          branch_at_cap = "feature/exactly-25-chars!"

          screen = render(app_with([entry(branch_at_cap)])).to_s

          aggregate_failures do
            expect(branch_at_cap.length).to eq(Ui::BRANCH_COLUMN_MAX)
            expect(screen).to include(branch_at_cap)
            expect(screen).not_to include("\u{2026}")
          end
        end

        it "truncates a branch past the cap with an ellipsis" do
          screen = render(app_with([entry("feature/ATT-6678-qa-feedback-1")])).to_s

          aggregate_failures do
            expect(screen).to include("feature/ATT-6678-qa-feed\u{2026}")
            expect(screen).not_to include("feedback")
          end
        end
      end

      describe "agent indicators" do
        def app_with_agent(state)
          app = app_with([entry("main", has_window: true)])
          app.agent_states["main"] = Orn::Detect::PaneAgentState.new(
            agent: :claude,
            state: state
          )
          app
        end

        it "labels a working agent" do
          expect(render(app_with_agent(:working), width: 80).to_s).to include("working")
        end

        it "labels a blocked agent with a filled circle" do
          screen = render(app_with_agent(:blocked), width: 80).to_s

          aggregate_failures do
            expect(screen).to include("\u{25cf}")
            expect(screen).to include("blocked")
          end
        end

        it "labels an idle agent" do
          expect(render(app_with_agent(:idle), width: 80).to_s).to include("idle")
        end

        it "renders the indicator without the selection highlight on an unselected row" do
          app = app_with([entry("main", has_window: true), entry("dev")])
          app.agent_states["main"] = Orn::Detect::PaneAgentState.new(
            agent: :claude,
            state: :idle
          )
          app.selected = 1

          buffer = render(app, width: 80)
          row_text = (0...80).map { |x| buffer[[x, 2]].symbol }.join
          label_x = row_text.index("idle")

          aggregate_failures do
            expect(label_x).not_to be_nil
            expect(buffer[[label_x, 2]].fg).to eq(Color::GREEN)
            expect(buffer[[label_x, 2]].bg).to eq(Color::RESET)
          end
        end

        it "shows no status when no agent is detected" do
          screen = render(app_with([entry("main", has_window: true)]), width: 80).to_s

          aggregate_failures do
            expect(screen).not_to include("working")
            expect(screen).not_to include("blocked")
            expect(screen).not_to include("idle")
          end
        end

        it "shows no status when the pane has no agent" do
          app = app_with([entry("main", has_window: true)])
          app.agent_states["main"] = Orn::Detect::PaneAgentState.new(
            agent: nil,
            state: :unknown
          )

          expect(render(app, width: 80).to_s).not_to include("idle")
        end
      end
    end
  end
end
