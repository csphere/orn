# frozen_string_literal: true

RSpec.describe Orn::Fs do
  describe ".prune_empty_dirs" do
    it "removes empty branch directories" do
      project = make_bare_project
      FileUtils.mkdir_p(File.join(project, "feature/old"))

      described_class.prune_empty_dirs(project)

      expect(File.exist?(File.join(project, "feature/old"))).to be(false)
      expect(File.exist?(File.join(project, "feature"))).to be(false)
    end

    it "keeps dot-directories" do
      project = make_bare_project
      FileUtils.mkdir_p(File.join(project, "feature/old"))

      described_class.prune_empty_dirs(project)

      expect(File.directory?(File.join(project, ".bare"))).to be(true)
      expect(File.directory?(File.join(project, ".orn"))).to be(true)
    end

    it "preserves directories that contain files" do
      project = make_bare_project
      FileUtils.mkdir_p(File.join(project, "feature/ABC-1234"))
      File.write(File.join(project, "feature/ABC-1234/.git"), "gitdir: ...")

      described_class.prune_empty_dirs(project)

      expect(File.exist?(File.join(project, "feature/ABC-1234"))).to be(true)
    end
  end

  describe ".xdg_dir" do
    context "when the variable is set" do
      it "returns its value" do
        ENV["XDG_DATA_HOME"] = "/custom/data"

        expect(described_class.xdg_dir("XDG_DATA_HOME", ".local/share")).to eq("/custom/data")
      end
    end

    context "when the variable is empty" do
      it "falls back to a path under the home directory" do
        ENV["XDG_DATA_HOME"] = ""
        ENV["HOME"] = "/home/tester"

        expect(described_class.xdg_dir("XDG_DATA_HOME", ".local/share")).to eq("/home/tester/.local/share")
      end
    end

    context "when neither the variable nor HOME is set" do
      it "returns nil" do
        ENV.delete("XDG_DATA_HOME")
        ENV.delete("HOME")

        expect(described_class.xdg_dir("XDG_DATA_HOME", ".local/share")).to be_nil
      end
    end
  end
end
