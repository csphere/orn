# frozen_string_literal: true

RSpec.describe Orn::Git::Repo do
  def repo_for(dir)
    described_class.new(
      dir: dir,
      output_mode: Orn::OutputMode.default
    )
  end

  describe "#output" do
    it "prepends git -C <dir> to the argv" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "status", "--porcelain"])

        repo_for("/project").output("status", "--porcelain")

        expect(fake.invocations).to eq([["git", "-C", "/project", "status", "--porcelain"]])
      end
    end

    it "returns the result on success" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "status"], stdout: "clean\n")

        result = repo_for("/project").output("status")

        expect(result).to be_success
        expect(result.stdout).to eq("clean\n")
      end
    end

    it "returns the result on a nonzero exit without raising" do
      with_fake_cmd do |fake|
        fake.script(
          ["git", "-C", "/project", "status"],
          stderr: "boom",
          status: 1
        )

        result = repo_for("/project").output("status")

        expect(result).not_to be_success
        expect(result.stderr).to eq("boom")
      end
    end
  end

  describe "#run" do
    it "returns the result on success" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "fetch"], stdout: "done\n")

        expect(repo_for("/project").run("fetch").stdout).to eq("done\n")
      end
    end

    it "raises with the stderr text on a nonzero exit" do
      with_fake_cmd do |fake|
        fake.script(
          ["git", "-C", "/project", "fetch"],
          stderr: "no remote",
          status: 1
        )

        expect { repo_for("/project").run("fetch") }
          .to raise_error(Orn::Error, /git failed: no remote/)
      end
    end

    it "raises command-not-found when git is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(["git", "-C", "/project", "fetch"])

        expect { repo_for("/project").run("fetch") }
          .to raise_error(Orn::Error, /command not found/)
      end
    end
  end

  describe "#exec" do
    it "returns nil on success" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "fetch"])

        expect(repo_for("/project").exec("fetch")).to be_nil
      end
    end

    it "raises on a nonzero exit" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "fetch"], status: 1)

        expect { repo_for("/project").exec("fetch") }
          .to raise_error(Orn::Error)
      end
    end
  end

  describe "#ok?" do
    it "returns true on a zero exit" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "check-ignore", "-q", "doc"])

        expect(repo_for("/project").ok?("check-ignore", "-q", "doc")).to be(true)
      end
    end

    it "returns false on a nonzero exit" do
      with_fake_cmd do |fake|
        fake.script(
          ["git", "-C", "/project", "check-ignore", "-q", "doc"],
          status: 1
        )

        expect(repo_for("/project").ok?("check-ignore", "-q", "doc")).to be(false)
      end
    end

    it "returns false when git is missing instead of raising" do
      with_fake_cmd do |fake|
        fake.script_missing(["git", "-C", "/project", "check-ignore", "-q", "doc"])

        expect(repo_for("/project").ok?("check-ignore", "-q", "doc")).to be(false)
      end
    end
  end

  describe "#read" do
    it "returns stdout on success" do
      with_fake_cmd do |fake|
        fake.script(
          ["git", "-C", "/project", "status", "--porcelain"],
          stdout: " M file\n"
        )

        expect(repo_for("/project").read("status", "--porcelain")).to eq(" M file\n")
      end
    end

    it "returns nil on a nonzero exit" do
      with_fake_cmd do |fake|
        fake.script(
          ["git", "-C", "/project", "status", "--porcelain"],
          status: 1
        )

        expect(repo_for("/project").read("status", "--porcelain")).to be_nil
      end
    end

    it "returns nil when git is missing instead of raising" do
      with_fake_cmd do |fake|
        fake.script_missing(["git", "-C", "/project", "status", "--porcelain"])

        expect(repo_for("/project").read("status", "--porcelain")).to be_nil
      end
    end
  end

  describe "dir coercion" do
    it "converts a Pathname dir to a string in the argv" do
      with_fake_cmd do |fake|
        fake.script(["git", "-C", "/project", "status"])

        repo_for(Pathname.new("/project")).output("status")

        expect(fake.invocations).to eq([["git", "-C", "/project", "status"]])
      end
    end
  end

  describe "env forwarding" do
    # FakeCmd ignores spawn options, so a bespoke recording backend asserts
    # the env hash reaches the backend's capture call.
    it "passes env through to the backend" do
      captured_env = nil
      recorder = Object.new
      recorder.define_singleton_method(:capture) do |_command, env: nil, **_options|
        captured_env = env
        Orn::Cmd::Result.new(
          stdout: "",
          stderr: "",
          status: 0
        )
      end
      Orn::Cmd.backend = recorder

      repo = described_class.new(
        dir: "/project",
        output_mode: Orn::OutputMode.default,
        env: { "GIT_CONFIG_NOSYSTEM" => "1" }
      )
      repo.output("config", "user.name")

      expect(captured_env).to eq({ "GIT_CONFIG_NOSYSTEM" => "1" })
    end
  end
end
