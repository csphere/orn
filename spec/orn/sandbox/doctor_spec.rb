# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Orn::Sandbox::Doctor do
  describe ".tool_check" do
    let(:mode) { Orn::OutputMode.default }

    it "passes when the tool is on PATH" do
      with_fake_cmd do |fake|
        fake.script(%w[which docker])

        expect(described_class.tool_check(mode, "docker")).to have_attributes(
          name: "docker",
          severity: :error,
          passed: true,
          message: "docker found on PATH"
        )
      end
    end

    it "fails when the tool is missing" do
      with_fake_cmd do |fake|
        fake.script(%w[which docker], status: 1)

        expect(described_class.tool_check(mode, "docker")).to have_attributes(
          passed: false,
          message: "docker not found on PATH"
        )
      end
    end
  end

  describe ".colima_check" do
    let(:mode) { Orn::OutputMode.default }

    it "fails when colima reports it is not running" do
      with_fake_cmd do |fake|
        fake.script(%w[colima status --json], status: 1)

        expect(described_class.colima_check(mode)).to have_attributes(
          name: "colima",
          severity: :error,
          passed: false,
          message: "Colima not running"
        )
      end
    end

    it "fails when the colima binary is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(%w[colima status --json])

        expect(described_class.colima_check(mode).passed).to be(false)
      end
    end

    it "reports the VM architecture when the status is JSON" do
      with_fake_cmd do |fake|
        fake.script(%w[colima status --json], stdout: '{"arch": "aarch64"}')

        expect(described_class.colima_check(mode)).to have_attributes(
          passed: true,
          message: "Colima running (aarch64)"
        )
      end
    end

    it "passes without an architecture when the status is not JSON" do
      with_fake_cmd do |fake|
        fake.script(%w[colima status --json], stdout: "colima is running\n")

        expect(described_class.colima_check(mode)).to have_attributes(
          passed: true,
          message: "Colima running"
        )
      end
    end
  end

  describe ".template_check" do
    let(:mode) { Orn::OutputMode.default }

    it "passes when the template is listed" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx template ls], stdout: "docker.io/library/img   1   0464b62418c6\n")

        expect(described_class.template_check(mode, "img:1")).to have_attributes(
          name: "template",
          severity: :error,
          passed: true,
          message: "Template 'img:1' found"
        )
      end
    end

    it "fails when the template is absent" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx template ls], stdout: "No template images found\n")

        expect(described_class.template_check(mode, "img:1")).to have_attributes(
          passed: false,
          message: "Template 'img:1' not found"
        )
      end
    end

    it "fails when the listing cannot run at all" do
      with_fake_cmd do |fake|
        fake.script_missing(%w[sbx template ls])

        expect(described_class.template_check(mode, "img:1").passed).to be(false)
      end
    end
  end

  describe ".path_check" do
    it "passes for an existing path" do
      dir = Dir.mktmpdir

      expect(described_class.path_check("kit", dir).passed).to be(true)
    ensure
      FileUtils.remove_entry(dir, true)
    end

    it "fails for a missing path" do
      expect(described_class.path_check("dockerfile", "/nonexistent/Dockerfile").passed).to be(false)
    end
  end

  describe ".env_check_with" do
    it "passes when the lookup finds a value" do
      expect(described_class.env_check_with("MY_VAR") { |_| "val" }.passed).to be(true)
    end

    it "fails when the lookup finds nothing" do
      expect(described_class.env_check_with("MY_VAR") { |_| nil }.passed).to be(false)
    end
  end

  describe ".git_identity_check", :real_cmd do
    def set_git_config(root, key, value)
      config_path = File.join(
        root,
        ".bare",
        "config"
      )
      git(
        "config",
        "--file",
        config_path,
        key,
        value
      )
    end

    let(:mode) { Orn::OutputMode.default }

    it "passes when both name and email are set" do
      root = make_bare_project
      set_git_config(
        root,
        "user.name",
        "Test User"
      )
      set_git_config(
        root,
        "user.email",
        "test@example.com"
      )

      check = described_class.git_identity_check(mode, root)

      expect(check).to have_attributes(
        passed: true,
        severity: :error,
        name: "git-identity"
      )
    end

    it "fails and suggests setting the name when it is missing" do
      root = make_bare_project
      set_git_config(
        root,
        "user.email",
        "test@example.com"
      )

      check = described_class.git_identity_check(mode, root)

      aggregate_failures do
        expect(check.passed).to be(false)
        expect(check.message).to include("git config --local user.name")
      end
    end

    it "fails and suggests setting the email when it is missing" do
      root = make_bare_project
      set_git_config(
        root,
        "user.name",
        "Test User"
      )

      check = described_class.git_identity_check(mode, root)

      aggregate_failures do
        expect(check.passed).to be(false)
        expect(check.message).to include("git config --local user.email")
      end
    end

    it "fails when both are missing" do
      check = described_class.git_identity_check(mode, make_bare_project)

      expect(check).to have_attributes(
        passed: false,
        severity: :error
      )
    end

    it "fails when the git binary is missing" do
      root = make_bare_project
      config_path = File.join(
        root,
        ".bare",
        "config"
      )

      with_fake_cmd do |fake|
        fake.script_missing(["git", "-C", Dir.tmpdir, "config", "--file", config_path, "user.name"])
        fake.script_missing(["git", "-C", Dir.tmpdir, "config", "--file", config_path, "user.email"])

        check = described_class.git_identity_check(mode, root)

        expect(check.passed).to be(false)
      end
    end
  end

  describe ".ssh_auth_check" do
    it "is a warning-kind check" do
      expect(described_class.ssh_auth_check).to have_attributes(
        severity: :warning,
        name: "ssh-auth"
      )
    end

    it "passes when SSH_AUTH_SOCK is set" do
      ENV["SSH_AUTH_SOCK"] = "/tmp/agent.sock"

      expect(described_class.ssh_auth_check.passed).to be(true)
    end

    it "warns that pushes will fail when SSH_AUTH_SOCK is unset" do
      ENV.delete("SSH_AUTH_SOCK")

      check = described_class.ssh_auth_check

      aggregate_failures do
        expect(check.passed).to be(false)
        expect(check.message).to include("git push")
      end
    end
  end

  describe ".github_secret_check" do
    let(:mode) { Orn::OutputMode.default }

    it "is a warning-kind check" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx secret ls], stdout: "github\n")

        expect(described_class.github_secret_check(mode)).to have_attributes(
          severity: :warning,
          name: "github-secret"
        )
      end
    end

    it "passes when a github secret is listed" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx secret ls], stdout: "NAME      CREATED\ngithub    2026-01-01\n")

        expect(described_class.github_secret_check(mode)).to have_attributes(
          passed: true,
          message: "github secret configured"
        )
      end
    end

    it "warns with the setup command when no github secret is listed" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx secret ls], stdout: "NAME      CREATED\nother     2026-01-01\n")

        check = described_class.github_secret_check(mode)

        aggregate_failures do
          expect(check.passed).to be(false)
          expect(check.message).to include("sbx secret set -g github")
        end
      end
    end

    it "warns when the secret listing fails" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx secret ls], status: 1)

        expect(described_class.github_secret_check(mode).passed).to be(false)
      end
    end

    it "warns when the sbx binary is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(%w[sbx secret ls])

        expect(described_class.github_secret_check(mode).passed).to be(false)
      end
    end
  end

  describe ".preflight" do
    before { stub_host_os("linux") }

    let(:mode) { Orn::OutputMode.default }
    let(:project) { make_project(make_bare_project, "sbx: {}\n") }

    # The git identity probe runs through Cmd like every other check, so the
    # fake backend scripts its two `git config` lookups directly.
    def script_git_identity(fake, root, status:)
      config_path = File.join(
        root,
        ".bare",
        "config"
      )
      fake.script(
        ["git", "-C", Dir.tmpdir, "config", "--file", config_path, "user.name"],
        stdout: "T\n",
        status: status
      )
      fake.script(
        ["git", "-C", Dir.tmpdir, "config", "--file", config_path, "user.email"],
        stdout: "t@t.com\n",
        status: status
      )
    end

    it "raises on the first failing error-level check and points at doctor" do
      with_fake_cmd do |fake|
        fake.script(%w[which sbx], status: 1)
        fake.script(%w[which docker])
        script_git_identity(
          fake,
          project.root,
          status: 1
        )
        fake.script(%w[sbx secret ls], stdout: "github\n")

        expect do
          described_class.preflight(
            mode,
            project.config.sbx,
            project.root
          )
        end.to raise_error(Orn::Error, /Preflight check failed: sbx not found on PATH\n.*orn sbx doctor/)
      end
    end

    it "prints warnings and continues when only warning-level checks fail" do
      ENV["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
      with_fake_cmd do |fake|
        fake.script(%w[which sbx])
        fake.script(%w[which docker])
        script_git_identity(
          fake,
          project.root,
          status: 0
        )
        fake.script(%w[sbx secret ls], stdout: "")

        expect do
          described_class.preflight(
            mode,
            project.config.sbx,
            project.root
          )
        end.to output(/Warning: No github secret configured/).to_stderr
      end
    end
  end

  describe ".run", :real_cmd do
    let(:mode) { Orn::OutputMode.default }
    let(:project) { make_project(make_bare_project, config_yaml) }
    let(:config_yaml) { "sbx: {}\n" }

    it "includes the git-identity, ssh-auth, and github-secret checks" do
      names = described_class.run(
        mode,
        project.config.sbx,
        project.root
      ).map(&:name)

      expect(names).to include(
        "git-identity",
        "ssh-auth",
        "github-secret"
      )
    end

    it "skips the colima check off macOS" do
      stub_host_os("linux")

      names = described_class.run(
        mode,
        project.config.sbx,
        project.root
      ).map(&:name)

      expect(names).not_to include("colima")
    end

    it "includes the colima check on macOS" do
      stub_host_os("darwin23")

      names = described_class.run(
        mode,
        project.config.sbx,
        project.root
      ).map(&:name)

      expect(names).to include("colima")
    end

    context "with a template and build args configured" do
      let(:config_yaml) { "sbx:\n  template: img:1\n  build:\n    build_args: [MY_BUILD_ARG]\n" }

      it "includes the template and per-build-arg env checks" do
        names = described_class.run(
          mode,
          project.config.sbx,
          project.root
        ).map(&:name)

        expect(names).to include("template", "env:MY_BUILD_ARG")
      end
    end

    context "with a dockerfile configured" do
      let(:config_yaml) { "sbx:\n  build:\n    dockerfile: Dockerfile\n" }

      it "includes the dockerfile check" do
        names = described_class.run(
          mode,
          project.config.sbx,
          project.root
        ).map(&:name)

        expect(names).to include("dockerfile")
      end
    end
  end
end
