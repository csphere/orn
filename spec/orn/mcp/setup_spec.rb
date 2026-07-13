# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Mcp::Setup do
  around do |example|
    Dir.mktmpdir { |dir| example.metadata[:dir] = dir and example.run }
  end

  def config_path(example)
    File.join(example.metadata[:dir], ".claude.json")
  end

  describe ".register_into" do
    it "creates the config with an mcpServers.orn entry when absent", :aggregate_failures do |example|
      path = config_path(example)

      described_class.register_into(path, "/usr/bin/orn", ["mcp"], "orn")

      config = JSON.parse(File.read(path))
      expect(config["mcpServers"]["orn"]).to eq("command" => "/usr/bin/orn", "args" => ["mcp"])
    end

    it "writes pretty JSON terminated by a newline" do |example|
      path = config_path(example)

      described_class.register_into(path, "/usr/bin/orn", ["mcp"], "orn")

      contents = File.read(path)
      aggregate_failures do
        expect(contents).to end_with("}\n")
        expect(contents).to include("  \"mcpServers\"")
      end
    end

    it "preserves other top-level keys and existing servers" do |example|
      path = config_path(example)
      File.write(path, JSON.generate("theme" => "dark", "mcpServers" => { "other" => { "command" => "x" } }))

      described_class.register_into(path, "/usr/bin/orn", ["mcp"], "orn")

      config = JSON.parse(File.read(path))
      aggregate_failures do
        expect(config["theme"]).to eq("dark")
        expect(config["mcpServers"]["other"]).to eq("command" => "x")
        expect(config["mcpServers"]["orn"]["command"]).to eq("/usr/bin/orn")
      end
    end

    it "overwrites a stale orn entry" do |example|
      path = config_path(example)
      File.write(path, JSON.generate("mcpServers" => { "orn" => { "command" => "/old/orn", "args" => [] } }))

      described_class.register_into(path, "/new/orn", ["mcp"], "orn")

      expect(JSON.parse(File.read(path))["mcpServers"]["orn"]).to eq("command" => "/new/orn", "args" => ["mcp"])
    end

    it "raises when the existing config is not valid JSON" do |example|
      path = config_path(example)
      File.write(path, "not json")

      expect { described_class.register_into(path, "/usr/bin/orn", ["mcp"], "orn") }
        .to raise_error(Orn::Error, /not valid JSON/)
    end

    it "raises when the top-level config is not an object" do |example|
      path = config_path(example)
      File.write(path, "[1, 2, 3]")

      expect { described_class.register_into(path, "/usr/bin/orn", ["mcp"], "orn") }
        .to raise_error(Orn::Error, /not a JSON object/)
    end
  end
end
