# frozen_string_literal: true

RSpec.describe Orn::Blackboard do
  def project_root
    root = register_temp_dir(Dir.mktmpdir("orn-bb"))
    FileUtils.mkdir_p(File.join(root, ".orn"))
    root
  end

  def blackboard_path(root, *parts)
    File.join(root, ".orn/blackboard", *parts)
  end

  describe ".render_template" do
    it "fills in the branch name and leaves no placeholder" do
      rendered = described_class.render_template("issues/52")

      expect(rendered).to include("# issues/52")
      expect(rendered).to include("Branch: issues/52")
      expect(rendered).not_to include("<branch>")
    end

    it "works for any branch naming convention" do
      %w[feature/auth ABC-1234/fix-login main issues/52].each do |branch|
        rendered = described_class.render_template(branch)

        expect(rendered).to include("# #{branch}")
        expect(rendered).to include("Branch: #{branch}")
      end
    end
  end

  describe ".ensure_dir" do
    it "seeds the blackboard with PROTOCOL.md and TEMPLATE.md" do
      root = project_root

      described_class.ensure_dir(root)

      expect(File.read(blackboard_path(root, "PROTOCOL.md"))).to include("## Write protocol")
      expect(File.read(blackboard_path(root, "TEMPLATE.md"))).to include("## Status")
    end

    it "is idempotent, preserving user edits" do
      root = project_root
      FileUtils.mkdir_p(blackboard_path(root))
      File.write(blackboard_path(root, "PROTOCOL.md"), "custom content")

      described_class.ensure_dir(root)

      expect(File.read(blackboard_path(root, "PROTOCOL.md"))).to eq("custom content")
    end
  end

  describe ".create_entry" do
    it "writes a rendered blackboard.md, creating nested directories" do
      root = project_root
      FileUtils.mkdir_p(blackboard_path(root))

      path = described_class.create_entry(root, "issues/52")

      expect(path).to eq(blackboard_path(root, "issues/52/blackboard.md"))
      expect(File.directory?(blackboard_path(root, "issues/52"))).to be(true)
      expect(File.read(path)).to include("Branch: issues/52")
    end
  end

  describe ".remove_entry" do
    it "deletes the entry and prunes now-empty parents up to the root" do
      root = project_root
      FileUtils.mkdir_p(blackboard_path(root))
      described_class.create_entry(root, "issues/52")

      described_class.remove_entry(root, "issues/52")

      expect(File.exist?(blackboard_path(root, "issues"))).to be(false)
      expect(File.exist?(blackboard_path(root))).to be(true)
    end

    it "preserves parents that still hold a sibling entry" do
      root = project_root
      FileUtils.mkdir_p(blackboard_path(root))
      described_class.create_entry(root, "issues/52")
      described_class.create_entry(root, "issues/53")

      described_class.remove_entry(root, "issues/52")

      expect(File.exist?(blackboard_path(root, "issues/52"))).to be(false)
      expect(File.exist?(blackboard_path(root, "issues/53"))).to be(true)
      expect(File.exist?(blackboard_path(root, "issues"))).to be(true)
    end

    it "is silent when the entry is missing" do
      root = project_root
      FileUtils.mkdir_p(blackboard_path(root))

      expect { described_class.remove_entry(root, "issues/99") }.not_to raise_error
    end
  end
end
