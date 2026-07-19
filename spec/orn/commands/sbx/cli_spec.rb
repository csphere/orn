# frozen_string_literal: true

RSpec.describe Orn::Commands::Sbx::CLI do
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

  describe "new" do
    it "runs New with the branch" do
      new_command = stub_command(Orn::Commands::Sbx::New)

      described_class.start(
        [
          "new",
          "feature/x"
        ]
      )

      expect(Orn::Commands::Sbx::New).to have_received(:new).with(output_mode: Orn::OutputMode.default)
      expect(new_command).to have_received(:run).with("feature/x")
    end

    it "builds the output mode from the flags" do
      stub_command(Orn::Commands::Sbx::New)

      described_class.start(
        [
          "new",
          "feature/x",
          "--verbose",
          "--json"
        ]
      )

      expect(Orn::Commands::Sbx::New).to have_received(:new).with(
        output_mode: Orn::OutputMode.new(
          verbose: true,
          json: true
        )
      )
    end
  end

  describe "remove" do
    it "runs Remove with the branch" do
      remove_command = stub_command(Orn::Commands::Sbx::Remove)

      described_class.start(
        [
          "remove",
          "feature/x"
        ]
      )

      expect(remove_command).to have_received(:run).with("feature/x")
    end
  end

  describe "list" do
    it "runs List" do
      list_command = stub_command(Orn::Commands::Sbx::List)

      described_class.start(["list"])

      expect(list_command).to have_received(:run).with(no_args)
    end
  end

  describe "build" do
    it "runs Build" do
      build_command = stub_command(Orn::Commands::Sbx::Build)

      described_class.start(["build"])

      expect(build_command).to have_received(:run).with(no_args)
    end
  end

  describe "doctor" do
    it "runs Doctor" do
      doctor_command = stub_command(Orn::Commands::Sbx::Doctor)

      described_class.start(["doctor"])

      expect(doctor_command).to have_received(:run).with(no_args)
    end
  end
end
