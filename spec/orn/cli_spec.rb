# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::CLI do
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

    it "names the program orn in help output" do
      expect(described_class.basename).to eq("orn")
    end
  end

  describe "version" do
    it "prints the orn version" do
      expect { described_class.start(["version"]) }
        .to output("orn #{Orn::VERSION}\n").to_stdout
    end

    it "is reachable through the --version flag" do
      expect { described_class.start(["--version"]) }
        .to output("orn #{Orn::VERSION}\n").to_stdout
    end
  end

  describe "clone" do
    it "runs Clone with the url and the required base" do
      clone_command = stub_command(Orn::Commands::Clone)

      described_class.start(
        [
          "clone",
          "https://example.com/repo.git",
          "--base",
          "main"
        ]
      )

      expect(Orn::Commands::Clone).to have_received(:new).with(output_mode: Orn::OutputMode.default)
      expect(clone_command).to have_received(:run).with(
        "https://example.com/repo.git",
        "main"
      )
    end
  end

  describe "init" do
    it "runs Init with the default base" do
      init_command = stub_command(Orn::Commands::Init)

      described_class.start(["init"])

      expect(init_command).to have_received(:run).with("main")
    end

    it "builds the output mode from the global flags" do
      stub_command(Orn::Commands::Init)

      described_class.start(
        [
          "init",
          "--verbose",
          "--json"
        ]
      )

      expect(Orn::Commands::Init).to have_received(:new).with(
        output_mode: Orn::OutputMode.new(
          verbose: true,
          json: true
        )
      )
    end
  end

  describe "convert" do
    it "runs Convert with the base option, nil when omitted" do
      convert_command = stub_command(Orn::Commands::Convert)

      described_class.start(["convert"])

      expect(convert_command).to have_received(:run).with(nil)
    end
  end

  describe "switch" do
    it "runs Switch with the branch, base override, and sandbox flag" do
      switch_command = stub_command(Orn::Commands::Switch)

      described_class.start(
        [
          "switch",
          "feature/x",
          "--base",
          "dev",
          "--sbx"
        ]
      )

      expect(switch_command).to have_received(:run).with(
        "feature/x",
        base_override: "dev",
        sbx: true
      )
    end
  end

  describe "new (deprecated)" do
    it "warns on stderr and delegates to Switch" do
      switch_command = stub_command(Orn::Commands::Switch)

      expect do
        described_class.start(
          [
            "new",
            "feature/x"
          ]
        )
      end.to output(/`orn new` is deprecated/).to_stderr

      expect(switch_command).to have_received(:run).with(
        "feature/x",
        base_override: nil,
        sbx: false
      )
    end
  end

  describe "open (deprecated)" do
    it "warns on stderr and delegates to Switch without options" do
      switch_command = stub_command(Orn::Commands::Switch)

      expect do
        described_class.start(
          [
            "open",
            "feature/x"
          ]
        )
      end.to output(/`orn open` is deprecated/).to_stderr

      expect(switch_command).to have_received(:run).with("feature/x")
    end
  end

  describe "list" do
    it "runs List" do
      list_command = stub_command(Orn::Commands::List)

      described_class.start(["list"])

      expect(list_command).to have_received(:run).with(no_args)
    end
  end

  describe "remove" do
    it "runs Remove with the branches and the prune and force flags" do
      remove_command = stub_command(Orn::Commands::Remove)

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
        .to raise_error(Orn::Error, "remove requires at least one branch")
    end
  end

  describe "completions" do
    it "prints the completion script for the requested shell" do
      expect { described_class.start(%w[completions bash]) }
        .to output(Orn::Completions.script("bash")).to_stdout
    end
  end

  describe "complete" do
    it "prints no candidates outside a project" do
      expect do
        Dir.mktmpdir { |dir| Dir.chdir(dir) { described_class.start(["complete"]) } }
      end.not_to output.to_stdout
    end
  end
end
