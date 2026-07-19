# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Orn::Sandbox::Doctor do
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

  describe ".git_identity_check" do
    def set_git_config(root, key, value)
      config_path = File.join(
        root,
        ".bare",
        "config"
      )
      system(
        GitHelpers::GIT_ISOLATION_ENV,
        "git",
        "config",
        "--file",
        config_path,
        key,
        value,
        out: File::NULL,
        err: File::NULL
      )
    end

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

      check = described_class.git_identity_check(root)

      expect(check).to have_attributes(
        passed: true,
        kind: :error,
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

      check = described_class.git_identity_check(root)

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

      check = described_class.git_identity_check(root)

      aggregate_failures do
        expect(check.passed).to be(false)
        expect(check.message).to include("git config --local user.email")
      end
    end

    it "fails when both are missing" do
      check = described_class.git_identity_check(make_bare_project)

      expect(check).to have_attributes(
        passed: false,
        kind: :error
      )
    end
  end

  describe ".ssh_auth_check" do
    it "is a warning-kind check" do
      expect(described_class.ssh_auth_check).to have_attributes(
        kind: :warning,
        name: "ssh-auth"
      )
    end
  end

  describe ".github_secret_check" do
    it "is a warning-kind check" do
      expect(described_class.github_secret_check(Orn::OutputMode.default))
        .to have_attributes(
          kind: :warning,
          name: "github-secret"
        )
    end
  end

  describe ".run" do
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
      names = described_class.run(
        mode,
        project.config.sbx,
        project.root
      ).map(&:name)

      if described_class.send(:macos?)
        expect(names).to include("colima")
      else
        expect(names).not_to include("colima")
      end
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
  end
end
