# frozen_string_literal: true

require "tmpdir"

RSpec.describe Orn::Mcp::Tools do
  # Dispatch may reach project discovery; run in a non-project temp dir so it
  # fails cleanly instead of touching the real repository.
  def dispatch(name, arguments)
    Dir.mktmpdir { |dir| Dir.chdir(dir) { described_class.dispatch(name, arguments) } }
  end

  def error_text(result)
    result["content"][0]["text"]
  end

  describe ".definitions" do
    it "advertises seven tools, all with object schemas" do
      tools = described_class.definitions

      aggregate_failures do
        expect(tools.length).to eq(7)
        tools.each do |tool|
          expect(tool["inputSchema"]["type"]).to eq("object")
          expect(tool["inputSchema"]["properties"]).to be_a(Hash)
        end
      end
    end

    it "documents the destructive remote-delete boundary on worktree_remove" do
      remove = described_class.definitions.find { |tool| tool["name"] == "worktree_remove" }
      props = remove["inputSchema"]["properties"]

      aggregate_failures do
        expect(props["confirm_remote_delete"]["type"]).to eq("boolean")
        expect(remove["description"]).to include("DESTRUCTIVE", "confirm_remote_delete")
      end
    end
  end

  describe ".dispatch" do
    it "reports an unknown tool as an error" do
      result = dispatch("nonexistent", {})

      aggregate_failures do
        expect(result["isError"]).to be(true)
        expect(error_text(result)).to include("Unknown tool")
      end
    end

    it "rejects an invalid base branch on worktree_switch" do
      result = dispatch("worktree_switch", { "branch" => "feature/ok", "base" => "main..evil" })

      aggregate_failures do
        expect(result["isError"]).to be(true)
        expect(error_text(result)).to include("Invalid branch name")
      end
    end

    it "rejects a base branch containing a space" do
      result = dispatch("worktree_switch", { "branch" => "feature/ok", "base" => "bad name" })

      expect(error_text(result)).to include("Invalid branch name")
    end

    it "rejects a missing branch argument" do
      result = dispatch("worktree_switch", {})

      aggregate_failures do
        expect(result["isError"]).to be(true)
        expect(error_text(result)).to include("missing required argument", "branch")
      end
    end

    it "rejects a null branch argument" do
      expect(error_text(dispatch("worktree_switch", { "branch" => nil }))).to include("missing required argument")
    end

    it "rejects an empty branch argument" do
      expect(error_text(dispatch("sandbox_new", { "branch" => "" }))).to include("missing required argument")
    end

    it "rejects a missing branch for every branch tool" do
      aggregate_failures do
        %w[worktree_switch worktree_remove sandbox_new sandbox_remove].each do |tool|
          result = dispatch(tool, {})
          expect(result["isError"]).to be(true), "#{tool} should reject missing branch"
          expect(error_text(result)).to include("missing required argument")
        end
      end
    end

    it "reaches a dispatch arm (not Unknown tool) for every defined tool" do
      aggregate_failures do
        described_class.definitions.each do |tool|
          result = dispatch(tool["name"], {})
          next unless result["isError"]

          expect(error_text(result)).not_to include("Unknown tool"), "#{tool["name"]} should have a dispatch arm"
        end
      end
    end
  end
end
