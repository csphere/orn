# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Orn::TUI::State do
  around do |example|
    Dir.mktmpdir { |dir| example.metadata[:dir] = dir and example.run }
  end

  def path(example)
    File.join(example.metadata[:dir], "tui.json")
  end

  describe "defaults" do
    it "starts with an empty mru" do
      expect(described_class.new.mru).to be_empty
    end

    it "returns a default when loading a missing file" do
      expect(described_class.load_from("/tmp/nonexistent-orn-state.json").mru).to be_empty
    end

    it "returns a default when loading a malformed file" do |example|
      File.write(path(example), "not json")

      expect(described_class.load_from(path(example)).mru).to be_empty
    end

    it "defaults mru to empty when the field is not a hash" do |example|
      File.write(path(example), '{"mru": "bogus", "expanded": ["/a"]}')

      state = described_class.load_from(path(example))
      aggregate_failures do
        expect(state.mru).to be_empty
        expect(state).to be_expanded("/a")
      end
    end
  end

  describe ".load" do
    it "loads from the state path and remembers it so save writes back" do |example|
      ENV["XDG_STATE_HOME"] = example.metadata[:dir]
      seeded = described_class.new
      seeded.touch("/home/user/dev/orn")
      seeded.save_to(described_class.state_path)

      loaded = described_class.load
      loaded.set_expanded("/home/user/dev/orn", true)
      loaded.save

      reloaded = described_class.load_from(described_class.state_path)
      aggregate_failures do
        expect(loaded.timestamp("/home/user/dev/orn")).not_to be_nil
        expect(reloaded).to be_expanded("/home/user/dev/orn")
      end
    end
  end

  describe ".state_path" do
    it "lives under XDG state when a base directory resolves" do |example|
      ENV["XDG_STATE_HOME"] = example.metadata[:dir]

      expect(described_class.state_path).to eq(File.join(example.metadata[:dir], "orn", "tui.json"))
    end

    it "falls back to /tmp when neither XDG_STATE_HOME nor HOME is set" do
      ENV.delete("XDG_STATE_HOME")
      ENV.delete("HOME")

      expect(described_class.state_path).to eq("/tmp/orn-tui-state.json")
    end
  end

  describe "mru timestamps" do
    it "records a timestamp on touch and reads it back" do
      state = described_class.new
      state.touch("/home/user/dev/orn")

      expect(state.timestamp("/home/user/dev/orn")).not_to be_nil
    end

    it "returns nil for an unknown root" do
      expect(described_class.new.timestamp("/unknown")).to be_nil
    end

    it "round-trips through save and load" do |example|
      state = described_class.new
      state.touch("/home/user/dev/orn")
      state.save_to(path(example))

      expect(described_class.load_from(path(example)).timestamp("/home/user/dev/orn")).not_to be_nil
    end
  end

  describe "expanded set" do
    it "round-trips an expanded repo" do |example|
      state = described_class.new
      state.set_expanded("/home/user/dev/orn", true)
      state.save_to(path(example))

      loaded = described_class.load_from(path(example))
      aggregate_failures do
        expect(loaded).to be_expanded("/home/user/dev/orn")
        expect(loaded).not_to be_expanded("/home/user/dev/other")
      end
    end

    it "does not duplicate an entry expanded twice" do
      state = described_class.new
      state.set_expanded("/home/user/dev/orn", true)
      state.set_expanded("/home/user/dev/orn", true)

      expect(state.expanded).to eq(["/home/user/dev/orn"])
    end

    it "removes an entry when set to false" do
      state = described_class.new
      state.set_expanded("/home/user/dev/orn", true)
      state.set_expanded("/home/user/dev/orn", false)

      expect(state).not_to be_expanded("/home/user/dev/orn")
    end

    it "defaults expanded to empty when the field is absent" do |example|
      File.write(path(example), '{"mru": {"/a": "2026-01-01T00:00:00Z"}}')

      state = described_class.load_from(path(example))
      aggregate_failures do
        expect(state.expanded).to be_empty
        expect(state.timestamp("/a")).not_to be_nil
      end
    end
  end

  describe "#prune" do
    it "drops mru and expanded entries for roots no longer present" do
      state = described_class.new
      state.touch("/keep")
      state.touch("/gone")
      state.set_expanded("/keep", true)
      state.set_expanded("/gone", true)

      state.prune(["/keep"])

      aggregate_failures do
        expect(state.timestamp("/keep")).not_to be_nil
        expect(state.timestamp("/gone")).to be_nil
        expect(state).to be_expanded("/keep")
        expect(state).not_to be_expanded("/gone")
      end
    end
  end

  describe "#save" do
    it "does nothing when constructed without a path" do
      expect(described_class.new.save).to be_nil
    end
  end

  describe "#save_to" do
    it "creates parent directories" do |example|
      target = File.join(example.metadata[:dir], "deep/nested/tui.json")

      described_class.new.save_to(target)

      expect(File).to exist(target)
    end

    it "swallows the error when the target directory cannot be created" do |example|
      blocking_file = File.join(example.metadata[:dir], "blocker")
      File.write(blocking_file, "")
      target = File.join(blocking_file, "tui.json")

      expect(described_class.new.save_to(target)).to be_nil
    end
  end
end
