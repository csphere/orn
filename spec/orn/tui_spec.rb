# frozen_string_literal: true

module Orn
  RSpec.describe TUI do
    describe ".agent_indicator" do
      it "shows a filled red circle for a blocked agent" do
        expect(described_class.agent_indicator(:blocked, 0)).to eq(
          [
            "\u{25cf}",
            TUI::Color::RED,
            "blocked"
          ]
        )
      end

      it "shows a yellow spinner frame picked by tick for a working agent" do
        expect(described_class.agent_indicator(:working, 0)).to eq(
          [
            TUI::SPINNER_FRAMES[0],
            TUI::Color::YELLOW,
            "working"
          ]
        )
      end

      it "shows a green empty circle for an idle agent" do
        expect(described_class.agent_indicator(:idle, 0)).to eq(
          [
            "\u{25cb}",
            TUI::Color::GREEN,
            "idle"
          ]
        )
      end

      it "falls back to a gray dot labelled idle for an unknown state" do
        expect(described_class.agent_indicator(:mystery, 0)).to eq(
          [
            "\u{00b7}",
            TUI::Color::DARK_GRAY,
            "idle"
          ]
        )
      end

      it "cycles spinner frames as the tick advances" do
        first_symbol = described_class.agent_indicator(:working, 1).first
        wrapped_symbol = described_class.agent_indicator(
          :working,
          1 + TUI::SPINNER_FRAMES.length
        ).first

        aggregate_failures do
          expect(first_symbol).to eq(TUI::SPINNER_FRAMES[1])
          expect(wrapped_symbol).to eq(TUI::SPINNER_FRAMES[1])
        end
      end
    end

    describe ".fit" do
      it "pads a short value with spaces" do
        expect(described_class.fit("main", 8)).to eq("main    ")
      end

      it "returns an exact-width value untouched" do
        expect(described_class.fit("abcde", 5)).to eq("abcde")
      end

      it "truncates a long value to width with a trailing ellipsis" do
        expect(described_class.fit("abcdef", 5)).to eq("abcd\u{2026}")
      end

      it "reduces to a lone ellipsis at width 1" do
        expect(described_class.fit("abc", 1)).to eq("\u{2026}")
      end

      it "returns an empty string at width 0" do
        expect(described_class.fit("abc", 0)).to eq("")
      end

      it "pads an empty string to width" do
        expect(described_class.fit("", 3)).to eq("   ")
      end
    end

    describe ".relaunch_command" do
      around do |example|
        original_program_name = $PROGRAM_NAME
        $PROGRAM_NAME = "/opt/orn/bin/orn"
        example.run
      ensure
        $PROGRAM_NAME = original_program_name
      end

      it "re-execs orn under ORN_TUI with no flags by default" do
        expect(described_class.relaunch_command).to eq(
          "ORN_TUI=1 exec /opt/orn/bin/orn"
        )
      end

      it "appends the suffix for global-mode flags" do
        expect(described_class.relaunch_command(" -g")).to eq(
          "ORN_TUI=1 exec /opt/orn/bin/orn -g"
        )
      end
    end

    describe ".orn_executable" do
      it "expands a relative program name to an absolute path" do
        original_program_name = $PROGRAM_NAME
        $PROGRAM_NAME = "bin/orn"

        expect(described_class.orn_executable).to eq(
          File.join(
            Dir.pwd,
            "bin/orn"
          )
        )
      ensure
        $PROGRAM_NAME = original_program_name
      end
    end

    describe ".launch" do
      it "delegates to Bootstrap.run with the global flag" do
        allow(TUI::Bootstrap).to receive(:run)

        described_class.launch(global: true)

        expect(TUI::Bootstrap).to have_received(:run).with(global: true)
      end
    end
  end
end
