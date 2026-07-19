# frozen_string_literal: true

RSpec.describe Orn::Commands::Wt::CLI do
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
    it "runs New with the branch and the base option, nil when omitted" do
      new_command = stub_command(Orn::Commands::Wt::New)

      described_class.start(
        [
          "new",
          "feature/x"
        ]
      )

      expect(new_command).to have_received(:run).with(
        "feature/x",
        base_override: nil
      )
    end

    it "builds the output mode from the flags and passes the base through" do
      new_command = stub_command(Orn::Commands::Wt::New)

      described_class.start(
        [
          "new",
          "feature/x",
          "--base",
          "dev",
          "--verbose",
          "--json"
        ]
      )

      expect(Orn::Commands::Wt::New).to have_received(:new).with(
        output_mode: Orn::OutputMode.new(
          verbose: true,
          json: true
        )
      )
      expect(new_command).to have_received(:run).with(
        "feature/x",
        base_override: "dev"
      )
    end
  end

  describe "open" do
    it "runs Open with the branch" do
      open_command = stub_command(Orn::Commands::Wt::Open)

      described_class.start(
        [
          "open",
          "feature/x"
        ]
      )

      expect(Orn::Commands::Wt::Open).to have_received(:new).with(output_mode: Orn::OutputMode.default)
      expect(open_command).to have_received(:run).with("feature/x")
    end
  end

  describe "list" do
    it "runs List" do
      list_command = stub_command(Orn::Commands::Wt::List)

      described_class.start(["list"])

      expect(list_command).to have_received(:run).with(no_args)
    end
  end

  describe "remove" do
    it "runs Remove with the branches and the prune and force flags" do
      remove_command = stub_command(Orn::Commands::Wt::Remove)

      described_class.start(
        [
          "remove",
          "feature/a",
          "feature/b",
          "--prune",
          "--force"
        ]
      )

      expect(remove_command).to have_received(:run).with(
        [
          "feature/a",
          "feature/b"
        ],
        prune: true,
        force: true
      )
    end

    it "raises when no branch is given" do
      expect { described_class.start(["remove"]) }
        .to raise_error(Orn::Error, "wt remove requires at least one branch")
    end
  end

  describe "link" do
    it "runs Link" do
      link_command = stub_command(Orn::Commands::Wt::Link)

      described_class.start(["link"])

      expect(link_command).to have_received(:run).with(no_args)
    end
  end
end
