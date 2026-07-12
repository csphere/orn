# frozen_string_literal: true

RSpec.describe Orn::Session do
  def project_at(root)
    Orn::Git::Project.new(root: root, config: Orn::Config.load_from("/nonexistent", nil))
  end

  describe ".session_name" do
    it "uses the project directory name" do
      expect(described_class.session_name(project_at("/home/user/dev/my-project"))).to eq("my-project")
    end

    it "defaults to 'default' when there is no directory name" do
      expect(described_class.session_name(project_at("/"))).to eq("default")
    end

    it "prefers the configured session" do
      project = make_project(make_bare_project, "tmux:\n  session: custom-name\n")

      expect(described_class.session_name(project)).to eq("custom-name")
    end
  end

  describe ".session_belongs_to_project?" do
    it "matches the project root exactly" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/orn", "/home/user/dev/orn")).to be(true)
    end

    it "matches a worktree inside the project" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/orn/main", "/home/user/dev/orn")).to be(true)
    end

    it "matches a nested worktree" do
      nested = "/home/user/dev/orn/issues/108"

      expect(described_class.session_belongs_to_project?(nested, "/home/user/dev/orn")).to be(true)
    end

    it "rejects a sibling with a shared prefix" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/orn-other", "/home/user/dev/orn")).to be(false)
    end

    it "rejects an unrelated path" do
      expect(described_class.session_belongs_to_project?("/home/user/dev/api", "/home/user/dev/orn")).to be(false)
    end
  end

  describe ".suggest_name" do
    it "combines the parent and directory names" do
      expect(described_class.suggest_name("/home/user/work/api")).to eq("work-api")
    end

    it "uses the directory name alone when there is no parent" do
      expect(described_class.suggest_name("/api")).to eq("api")
    end
  end

  describe ".current_session" do
    it "returns nil when not inside tmux" do
      ENV.delete("TMUX")

      expect(described_class.current_session(Orn::OutputMode.default)).to be_nil
    end
  end
end
