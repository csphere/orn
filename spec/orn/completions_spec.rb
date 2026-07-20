# frozen_string_literal: true

RSpec.describe Orn::Completions do
  describe ".script" do
    it "generates a bash script that registers a completion and calls orn complete" do
      script = described_class.script("bash")

      aggregate_failures do
        expect(script).to include("complete -F _orn orn")
        expect(script).to include("$(orn complete)")
        expect(script).to include("switch")
      end
    end

    it "generates a zsh script with a compdef header" do
      script = described_class.script("zsh")

      aggregate_failures do
        expect(script).to start_with("#compdef orn")
        expect(script).to include("orn complete")
      end
    end

    it "generates a fish script with per-command completions" do
      script = described_class.script("fish")

      aggregate_failures do
        expect(script).to include("complete -c orn")
        expect(script).to include("(orn complete)")
      end
    end

    it "raises for an unsupported shell" do
      expect { described_class.script("powershell") }.to raise_error(Orn::Error, /Unsupported shell/)
    end
  end

  # Like the generated docs/cli.md check in CI, but in-process: the
  # completion command lists are hand-maintained, so pin them to the Thor
  # registry to catch a new or renamed command that forgot completion.
  describe "command list parity" do
    def visible_commands(cli_class)
      cli_class.commands.reject { |_, command| command.hidden? }.keys
    end

    it "keeps TOP_COMMANDS in sync with the root CLI (plus help)" do
      expect(described_class::TOP_COMMANDS).to match_array(visible_commands(Orn::CLI) + ["help"])
    end

    it "keeps WT_SUBCOMMANDS in sync with orn wt" do
      expect(described_class::WT_SUBCOMMANDS).to match_array(visible_commands(Orn::Commands::Wt::CLI) - ["help"])
    end

    it "keeps SBX_SUBCOMMANDS in sync with orn sbx" do
      expect(described_class::SBX_SUBCOMMANDS).to match_array(visible_commands(Orn::Commands::Sbx::CLI) - ["help"])
    end

    it "keeps CONFIG_SUBCOMMANDS in sync with orn config" do
      expect(described_class::CONFIG_SUBCOMMANDS)
        .to match_array(visible_commands(Orn::Commands::Config::CLI) - ["help"])
    end
  end
end
