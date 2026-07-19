# frozen_string_literal: true

RSpec.describe Orn::Commands::Config::CLI do
  def stub_command(command_class)
    command_instance = instance_double(command_class)
    allow(command_class).to receive(:new).and_return(command_instance)
    allow(command_instance).to receive(:run)
    command_instance
  end

  describe "Thor hooks" do
    it "exits nonzero on failure" do
      expect(described_class.exit_on_failure?).to be(true)
    end
  end

  describe "show" do
    it "runs Show with the default output mode" do
      show_command = stub_command(Orn::Commands::Config::Show)

      described_class.start(["show"])

      expect(Orn::Commands::Config::Show).to have_received(:new).with(output_mode: Orn::OutputMode.default)
      expect(show_command).to have_received(:run).with(no_args)
    end

    it "builds the output mode from the flags" do
      stub_command(Orn::Commands::Config::Show)

      described_class.start(
        [
          "show",
          "--verbose",
          "--json"
        ]
      )

      expect(Orn::Commands::Config::Show).to have_received(:new).with(
        output_mode: Orn::OutputMode.new(
          verbose: true,
          json: true
        )
      )
    end
  end

  describe "migrate" do
    it "runs Migrate with the flags off by default" do
      migrate_command = stub_command(Orn::Commands::Config::Migrate)

      described_class.start(["migrate"])

      expect(Orn::Commands::Config::Migrate).to have_received(:new).with(
        output_mode: Orn::OutputMode.default,
        dry_run: false,
        global_only: false,
        project_only: false
      )
      expect(migrate_command).to have_received(:run).with(no_args)
    end

    it "passes the dry-run and scope flags through" do
      stub_command(Orn::Commands::Config::Migrate)

      described_class.start(
        [
          "migrate",
          "--dry-run",
          "--global"
        ]
      )

      expect(Orn::Commands::Config::Migrate).to have_received(:new).with(
        output_mode: Orn::OutputMode.default,
        dry_run: true,
        global_only: true,
        project_only: false
      )
    end

    it "raises when both scope flags are given" do
      expect do
        described_class.start(
          [
            "migrate",
            "--global",
            "--project"
          ]
        )
      end.to raise_error(Orn::Error, "--global and --project cannot be used together")
    end
  end
end
