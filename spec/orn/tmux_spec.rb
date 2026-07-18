# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::Tmux do
  describe ".window_target" do
    it "joins session and window with a colon" do
      expect(described_class.window_target("work", "feature")).to eq("work:feature")
    end
  end

  describe ".shell_ready_command" do
    it "clears the screen and history before the ready signal, which comes last" do
      parts = described_class.shell_ready_command("orn-ready-42").split(";").map(&:strip)
      signal_index = parts.index { |part| part.include?("wait-for -S") }
      clear_index = parts.index("clear")
      history_index = parts.index { |part| part.include?("clear-history") }

      aggregate_failures do
        expect(clear_index).to be < signal_index
        expect(history_index).to be < signal_index
        expect(signal_index).to eq(parts.length - 1)
      end
    end
  end

  describe ".window_guard_condition" do
    it "builds a tmux condition matching only the given session and window" do
      condition = described_class.window_guard_condition("dev", "orn")

      expect(condition).to eq('#{&&:#{==:#{session_name},dev},#{==:#{window_name},orn}}')
    end
  end

  describe ".parse_pane_lines" do
    it "parses one metadata record per line" do
      output = "main\t12345\tclaude\t%0\tClaude Code\nfeature\t67890\tbash\t%1\t~/project\n"

      panes = described_class.parse_pane_lines(output, with_session: false)

      aggregate_failures do
        expect(panes.length).to eq(2)
        expect(panes[0]).to have_attributes(
          window_name: "main",
          pane_pid: 12_345,
          pane_current_command: "claude",
          pane_id: "%0",
          pane_title: "Claude Code",
          session_name: nil
        )
        expect(panes[1]).to have_attributes(
          window_name: "feature",
          pane_pid: 67_890,
          pane_current_command: "bash"
        )
      end
    end

    it "skips lines with the wrong field count" do
      output = "valid\t123\tcmd\t%0\ttitle\nonly\ttwo\nvalid\t456\tcmd2\t%1\ttitle2\n"

      panes = described_class.parse_pane_lines(output, with_session: false)

      expect(panes.map(&:pane_pid)).to eq([123, 456])
    end

    it "skips lines whose pid is not a number" do
      panes = described_class.parse_pane_lines("win\tnot_a_number\tcmd\t%0\ttitle\n", with_session: false)

      expect(panes).to be_empty
    end

    it "includes the session name for the all-sessions listing" do
      panes = described_class.parse_pane_lines("sess\tmain\t12345\tclaude\t%0\tTitle\n", with_session: true)

      expect(panes.first).to have_attributes(
        session_name: "sess",
        window_name: "main",
        pane_pid: 12_345,
        pane_title: "Title",
        pane_current_command: "claude",
        pane_id: "%0"
      )
    end

    it "keeps embedded tabs in the trailing title field" do
      panes = described_class.parse_pane_lines("sess\tmain\t12345\tclaude\t%0\tTitle\twith\ttabs\n", with_session: true)

      expect(panes.first).to have_attributes(
        pane_title: "Title\twith\ttabs",
        pane_id: "%0"
      )
    end

    it "returns nothing for empty input" do
      expect(described_class.parse_pane_lines("", with_session: false)).to be_empty
    end

    it "rejects an all-sessions line missing the session field" do
      panes = described_class.parse_pane_lines("main\t12345\tcmd\t%0\n", with_session: true)

      expect(panes).to be_empty
    end
  end

  describe ".parse_borrowed_lines" do
    it "keeps only panes with both home tags set" do
      output = "%0\t\t\n%3\tdev\tissues/270\n%5\tother\t\n"

      borrowed = described_class.parse_borrowed_lines(output)

      expect(borrowed).to eq(
        [described_class::BorrowedPane.new(
          pane_id: "%3",
          home_session: "dev",
          home_window: "issues/270"
        )]
      )
    end

    it "ignores lines without all three fields" do
      expect(described_class.parse_borrowed_lines("%1\n%2\tonly-one-field\n")).to be_empty
    end
  end

  context "with a real tmux server", if: TmuxSpecSupport::AVAILABLE do
    include_context "with an isolated tmux server"

    let(:output_mode) { Orn::OutputMode.quiet }
    let(:session) { "orn-tmux-spec" }
    # A column of two empty-command panes (a real split, no live-shell wait) and
    # an empty single-pane layout.
    let(:columns_layout) do
      Orn::Config::Layout.of_columns([Orn::Config::Column.new(panes: ["", ""])])
    end
    let(:one_pane_layout) { Orn::Config::Layout.of_columns([]) }

    def create_window_in(path, session, window, layout)
      described_class.create_window(output_mode, session, window, path, layout, default_window_name: window)
    end

    def pane_ids(session)
      described_class.list_panes_metadata(output_mode, session).map(&:pane_id)
    end

    it "adds a window to an existing session and can remove it" do
      Dir.mktmpdir do |path|
        described_class.ensure_session(output_mode, session, path)
        expect(described_class.window_exists?(output_mode, session, "feature")).to be(false)

        described_class.create_window(output_mode, session, "feature", path, columns_layout)

        expect(described_class.list_windows(output_mode, session)).to include("feature")
        expect(described_class.window_exists?(output_mode, session, "feature")).to be(true)

        described_class.kill_window(output_mode, session, "feature")
        expect(described_class.window_exists?(output_mode, session, "feature")).to be(false)
      end
    end

    it "creates the seed window directly when it is the default window" do
      Dir.mktmpdir do |path|
        described_class.create_window(output_mode, session, "main", path, columns_layout, default_window_name: "main")

        expect(described_class.list_windows(output_mode, session)).to eq(["main"])
      end
    end

    it "reports no windows for a session that does not exist" do
      expect(described_class.list_windows(output_mode, "orn-tmux-absent")).to eq([])
    end

    it "lists pane metadata for a session" do
      Dir.mktmpdir do |path|
        create_window_in(path, session, "feature", columns_layout)

        feature_panes = described_class.list_panes_metadata(output_mode, session)

        aggregate_failures do
          expect(feature_panes.length).to eq(2)
          expect(feature_panes.map(&:window_name)).to all(eq("feature"))
          expect(feature_panes).to all(have_attributes(session_name: nil))
          expect(feature_panes.map(&:pane_pid)).to all(be_positive)
          expect(feature_panes.map(&:pane_id)).to all(start_with("%"))
        end
      end
    end

    it "lists all panes across the server tagged with their session" do
      Dir.mktmpdir do |path|
        create_window_in(path, session, "feature", columns_layout)

        panes = described_class.list_all_panes_metadata(output_mode)

        aggregate_failures do
          expect(panes.length).to eq(2)
          expect(panes.map(&:session_name)).to all(eq(session))
        end
      end
    end

    it "returns nil from the all-panes listing when no server is running" do
      expect(described_class.list_all_panes_metadata(output_mode)).to be_nil
    end

    it "captures a pane's visible contents as a string" do
      Dir.mktmpdir do |path|
        create_window_in(path, session, "feature", columns_layout)
        pane_id = pane_ids(session).first

        expect(described_class.capture_pane(output_mode, pane_id)).to be_a(String)
      end
    end

    it "tags a pane, lists it as borrowed, then clears the tags" do
      Dir.mktmpdir do |path|
        create_window_in(path, "home-sess", "home-win", one_pane_layout)
        pane = pane_ids("home-sess").first
        described_class.set_pane_option(output_mode, pane, described_class::OPT_HOME_SESSION, "home-sess")
        described_class.set_pane_option(output_mode, pane, described_class::OPT_HOME_WINDOW, "home-win")

        expect(described_class.list_borrowed_panes(output_mode)).to contain_exactly(
          described_class::BorrowedPane.new(
            pane_id: pane,
            home_session: "home-sess",
            home_window: "home-win"
          )
        )

        described_class.unset_pane_option(output_mode, pane, described_class::OPT_HOME_SESSION)
        described_class.unset_pane_option(output_mode, pane, described_class::OPT_HOME_WINDOW)
        expect(described_class.list_borrowed_panes(output_mode)).to be_empty
      end
    end

    it "reports the session and window containing a pane" do
      Dir.mktmpdir do |path|
        create_window_in(path, "sess-a", "win-a", one_pane_layout)
        pane = pane_ids("sess-a").first

        expect(described_class.current_session_window(output_mode, pane)).to eq(%w[sess-a win-a])
      end
    end

    it "returns the active pane of a window" do
      Dir.mktmpdir do |path|
        create_window_in(path, "sess-b", "win-b", columns_layout)
        panes = pane_ids("sess-b")
        described_class.select_pane(output_mode, panes.last)

        expect(described_class.active_pane(output_mode, "sess-b", "win-b")).to eq(panes.last)
      end
    end

    it "borrows a pane into another window and breaks it back out" do
      Dir.mktmpdir do |path|
        create_window_in(path, "src", "work", columns_layout)
        borrowed = pane_ids("src").last
        create_window_in(path, "hub", "orn", one_pane_layout)

        described_class.join_pane(output_mode, borrowed, "hub:orn", 33, false)
        expect(pane_ids("hub")).to include(borrowed)

        described_class.break_pane(output_mode, borrowed, "src", "returned")
        expect(described_class.list_windows(output_mode, "src")).to include("returned")
      end
    end

    it "recreates a session around a surviving pane" do
      Dir.mktmpdir do |path|
        create_window_in(path, "orig", "w", columns_layout)
        pane = pane_ids("orig").last

        described_class.recreate_session_with_pane(output_mode, pane, "revived", "back")

        expect(described_class.list_windows(output_mode, "revived")).to eq(["back"])
      end
    end

    it "installs a guarded root key binding and removes it" do
      Dir.mktmpdir do |path|
        described_class.ensure_session(output_mode, "kb", path)
        condition = described_class.window_guard_condition("kb", "orn")
        described_class.bind_key_guarded(output_mode, "M-o", condition, "display-message borrowed")

        expect(root_key_bindings).to include("M-o")

        described_class.unbind_key(output_mode, "M-o")
        expect(root_key_bindings).not_to include("M-o")
      end
    end

    def root_key_bindings
      Orn::Cmd.new(output_mode: output_mode).output("tmux", "list-keys", "-T", "root").stdout
    end
  end
end
