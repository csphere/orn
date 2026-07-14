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

    context "with config-version enforcement" do
      before { allow(Orn::CLI).to receive(:start) }

      it "enforces config versions once a project is discovered" do
        allow(Orn::Git::Project).to receive(:discover_root).and_return("/proj")
        allow(Orn::Config::Migrate).to receive(:enforce_project_versions)

        described_class.new(["list"]).run

        expect(Orn::Config::Migrate).to have_received(:enforce_project_versions).with("/proj")
      end

      it "refuses to dispatch when a config is behind the running orn" do
        allow(Orn::Git::Project).to receive(:discover_root).and_return("/proj")
        allow(Orn::Config::Migrate).to receive(:enforce_project_versions)
          .and_raise(Orn::Error, "config version is behind orn")

        expect { described_class.new(["list"]).run }
          .to raise_error(Orn::Error, "config version is behind orn")
        expect(Orn::CLI).not_to have_received(:start)
      end

      it "dispatches normally when no project is found" do
        allow(Orn::Git::Project).to receive(:discover_root)
          .and_raise(Orn::Error, "Not an orn project")
        allow(Orn::Config::Migrate).to receive(:enforce_project_versions)

        described_class.new(["list"]).run

        expect(Orn::Config::Migrate).not_to have_received(:enforce_project_versions)
        expect(Orn::CLI).to have_received(:start).with(["list"])
      end

      %w[version help complete].each do |command|
        it "skips enforcement for the #{command} command" do
          allow(Orn::Git::Project).to receive(:discover_root)

          described_class.new([command]).run

          expect(Orn::Git::Project).not_to have_received(:discover_root)
        end
      end

      %w[--version -V --help -h].each do |flag|
        it "skips enforcement for the #{flag} flag" do
          allow(Orn::Git::Project).to receive(:discover_root)

          described_class.new([flag]).run

          expect(Orn::Git::Project).not_to have_received(:discover_root)
        end
      end
    end
  end
end
