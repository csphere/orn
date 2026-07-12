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

      it "keeps the verbose and json flags for the CLI" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["--json", "list", "-v"]).run

        expect(Orn::CLI).to have_received(:start).with(["--json", "list", "-v"])
      end

      it "strips the root-only global flag before dispatching" do
        allow(Orn::CLI).to receive(:start)

        described_class.new(["-g", "list"]).run

        expect(Orn::CLI).to have_received(:start).with(["list"])
      end
    end
  end
end
