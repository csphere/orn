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

  describe "#save_to" do
    it "creates parent directories" do |example|
      target = File.join(example.metadata[:dir], "deep/nested/tui.json")

      described_class.new.save_to(target)

      expect(File).to exist(target)
    end
  end
end
