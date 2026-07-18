# frozen_string_literal: true

require "stringio"
require "yaml"

RSpec.describe Orn::Commands::Setup do
  describe ".serialize_config" do
    it "produces valid YAML with the version and base branch" do
      parsed = YAML.safe_load(described_class.serialize_config("main"))

      expect(parsed["orn_version"]).to eq(Orn::VERSION)
      expect(parsed.dig("git", "base")).to eq("main")
    end

    it "escapes a base value so it cannot inject other keys" do
      parsed = YAML.safe_load(described_class.serialize_config("main\"\nsession: evil"))

      expect(parsed.dig("git", "base")).to eq("main\"\nsession: evil")
      expect(parsed).not_to have_key("session")
    end
  end

  describe ".serialize_global_config" do
    it "documents tmux and tui but no project-only keys" do
      config = described_class.serialize_global_config

      expect(YAML.safe_load(config)["orn_version"]).to eq(Orn::VERSION)
      expect(config).to include("tui:", "scan_roots", "scan_depth", "session: orn")
      expect(config).not_to include("git:\n  base")
    end
  end

  describe ".generate_claude_md" do
    it "fills in the project name and base branch and explains the layout" do
      content = described_class.generate_claude_md("acme-api", "develop")

      expect(content).to start_with("#")
      expect(content).to include("acme-api", "develop/", ".bare", "gitdir", "worktree")
    end
  end

  describe ".bootstrap_global_config" do
    def bootstrap(global_dir, input)
      writer = StringIO.new
      described_class.bootstrap_global_config(Orn::OutputMode.quiet, global_dir, StringIO.new(input), writer)
      writer.string
    end

    it "does nothing when there is no config dir" do
      expect(bootstrap(nil, "y\n")).to be_empty
    end

    it "does nothing when the config already exists" do
      dir = register_temp_dir(Dir.mktmpdir("orn-global"))
      File.write(File.join(dir, "default.yaml"), "# existing")

      bootstrap(dir, "y\n")

      expect(File.read(File.join(dir, "default.yaml"))).to eq("# existing")
    end

    it "creates the config (and parent dirs) when confirmed" do
      base = register_temp_dir(Dir.mktmpdir("orn-global"))
      dir = File.join(base, "deeply/nested/orn")

      bootstrap(dir, "y\n")

      expect(File.exist?(File.join(dir, "default.yaml"))).to be(true)
    end

    it "does not create the config when declined" do
      base = register_temp_dir(Dir.mktmpdir("orn-global"))
      dir = File.join(base, "orn")

      bootstrap(dir, "n\n")

      expect(File.exist?(File.join(dir, "default.yaml"))).to be(false)
    end
  end
end
