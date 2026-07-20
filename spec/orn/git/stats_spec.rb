# frozen_string_literal: true

RSpec.describe Orn::Git::Stats do
  def git_argv(root, *args)
    ["git", "-C", root, *args]
  end

  describe "Git::Stats.dirty?" do
    def status_argv
      git_argv(
        "/repo/feat",
        "status",
        "--porcelain"
      )
    end

    def query_dirty
      Orn::Git::Stats.dirty?(
        Orn::OutputMode.quiet,
        "/repo/feat"
      )
    end

    it "is true when git reports changes" do
      with_fake_cmd do |fake|
        fake.script(status_argv, stdout: " M f.txt\n")

        expect(query_dirty).to be(true)
      end
    end

    it "is false when the tree is clean" do
      with_fake_cmd do |fake|
        fake.script(status_argv, stdout: "\n")

        expect(query_dirty).to be(false)
      end
    end

    it "is false when git exits nonzero" do
      with_fake_cmd do |fake|
        fake.script(status_argv, status: 128)

        expect(query_dirty).to be(false)
      end
    end

    it "is false when git is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(status_argv)

        expect(query_dirty).to be(false)
      end
    end
  end

  describe "Git::Stats.ahead_behind", :real_cmd do
    def rev_list_argv
      git_argv(
        "/repo/feat",
        "rev-list",
        "--left-right",
        "--count",
        "feat...main"
      )
    end

    def query_counts
      Orn::Git::Stats.ahead_behind(
        Orn::OutputMode.quiet,
        "/repo/feat",
        "feat",
        "main"
      )
    end

    it "parses the left-right counts" do
      with_fake_cmd do |fake|
        fake.script(rev_list_argv, stdout: "2\t1\n")

        expect(query_counts).to eq([2, 1])
      end
    end

    it "returns zeros for malformed output" do
      with_fake_cmd do |fake|
        fake.script(rev_list_argv, stdout: "garbage\n")

        expect(query_counts).to eq([0, 0])
      end
    end

    it "returns zeros when git exits nonzero" do
      with_fake_cmd do |fake|
        fake.script(rev_list_argv, status: 128)

        expect(query_counts).to eq([0, 0])
      end
    end

    it "returns zeros when git is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(rev_list_argv)

        expect(query_counts).to eq([0, 0])
      end
    end

    it "returns zeros for an invalid path" do
      counts = described_class.ahead_behind(
        Orn::OutputMode.quiet,
        "/tmp/nonexistent",
        "feature",
        "main"
      )

      expect(counts).to eq([0, 0])
    end
  end
end
