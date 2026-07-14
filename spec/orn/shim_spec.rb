# frozen_string_literal: true

RSpec.describe Orn::Shim do
  describe "#run" do
    context "with no subcommand" do
      it "launches the project TUI" do
        allow(Orn::TUI).to receive(:launch)

        described_class.new([]).run

        expect(Orn::TUI).to have_received(:launch).with(global: false)
      end
    end

    context "with only the global flag" do
      it "launches the global TUI" do
        allow(Orn::TUI).to receive(:launch)

        described_class.new(["-g"]).run

        expect(Orn::TUI).to have_received(:launch).with(global: true)
      end
    end

    context "with a subcommand" do
      it "dispatches to the CLI" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["list"]).run

        expect(Orn::CLI).to have_received(:start).with(["list"])
      end

      it "keeps a trailing global flag in place for the CLI" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["list", "-v"]).run

        expect(Orn::CLI).to have_received(:start).with(["list", "-v"])
      end

      it "relocates a leading global flag past a top-level command" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["--json", "list"]).run

        expect(Orn::CLI).to have_received(:start).with(["list", "--json"])
      end

      it "relocates a leading global flag past a subcommand-group command" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["--json", "config", "show"]).run

        expect(Orn::CLI).to have_received(:start).with(["config", "show", "--json"])
      end

      it "relocates a leading global flag but keeps a trailing one in place" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["--json", "list", "-v"]).run

        expect(Orn::CLI).to have_received(:start).with(["list", "-v", "--json"])
      end

      it "strips the leading root-only global flag before dispatching" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["-g", "list"]).run

        expect(Orn::CLI).to have_received(:start).with(["list"])
      end

      it "keeps a subcommand's own --global flag" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["config", "migrate", "--global"]).run

        expect(Orn::CLI).to have_received(:start).with(["config", "migrate", "--global"])
      end
    end
  end
end
