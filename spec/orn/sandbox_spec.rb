# frozen_string_literal: true

require "socket"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Sandbox do
  describe Orn::Sandbox::PortMapping do
    it "displays as host:container" do
      expect(
        described_class.new(
          host: 3042,
          container: 3000
        ).to_s
      ).to eq("3042:3000")
    end
  end

  describe ".reserve_port" do
    it "finds a free port in the range" do
      expect(described_class.reserve_port([49_152, 49_252])).to be_between(49_152, 49_252)
    end

    it "skips an occupied port" do
      listener = TCPServer.new("127.0.0.1", 59_300)

      found = described_class.reserve_port([59_300, 59_302])

      aggregate_failures do
        expect(found).not_to eq(59_300)
        expect(found).to be_between(59_301, 59_302)
      end
    ensure
      listener&.close
    end

    it "raises when the range is exhausted" do
      first = TCPServer.new("127.0.0.1", 59_400)
      second = TCPServer.new("127.0.0.1", 59_401)

      expect { described_class.reserve_port([59_400, 59_401]) }.to raise_error(Orn::Error, /No free port/)
    ensure
      first&.close
      second&.close
    end
  end

  describe ".verify_port" do
    it "succeeds when a listener is accepting connections" do
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]

      expect do
        described_class.verify_port(
          port,
          1,
          0.01
        )
      end.not_to raise_error
    ensure
      listener&.close
    end

    it "times out when the port never opens" do
      expect do
        described_class.verify_port(
          1,
          0.2,
          0.05
        )
      end.to raise_error(Orn::Error, /not reachable/)
    end
  end

  describe "port persistence" do
    let(:orn_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(orn_dir, true) }

    it "round-trips a single mapping" do
      mappings = [
        Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        )
      ]
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        mappings
      )

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "round-trips multiple mappings" do
      mappings = [
        Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        ),
        Orn::Sandbox::PortMapping.new(
          host: 6380,
          container: 6379
        )
      ]
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        mappings
      )

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "creates the sandbox directory" do
      described_class.persist_ports(
        orn_dir,
        "test",
        [
          Orn::Sandbox::PortMapping.new(
            host: 8080,
            container: 80
          )
        ]
      )

      expect(File).to exist(
        File.join(
          orn_dir,
          "sandbox",
          "test.ports"
        )
      )
    end

    it "raises when reading a missing file" do
      expect { described_class.read_ports(orn_dir, "nonexistent") }.to raise_error(Orn::Error, /Failed to read/)
    end

    it "removes the ports file" do
      described_class.persist_ports(
        orn_dir,
        "my-sbx",
        [
          Orn::Sandbox::PortMapping.new(
            host: 3042,
            container: 3000
          )
        ]
      )

      described_class.remove_ports_file(orn_dir, "my-sbx")

      expect(File).not_to exist(
        File.join(
          orn_dir,
          "sandbox",
          "my-sbx.ports"
        )
      )
    end

    it "cleans up the legacy single-port file" do
      sandbox_dir = File.join(orn_dir, "sandbox")
      FileUtils.mkdir_p(sandbox_dir)
      File.write(File.join(sandbox_dir, "my-sbx.port"), "3042")

      described_class.remove_ports_file(orn_dir, "my-sbx")

      expect(File).not_to exist(File.join(sandbox_dir, "my-sbx.port"))
    end

    it "ignores a missing file on removal" do
      expect { described_class.remove_ports_file(orn_dir, "nonexistent") }.not_to raise_error
    end
  end

  describe Orn::Sandbox::Check do
    it "builds a passing error check" do
      check = described_class.pass("test", "ok")

      expect(check).to have_attributes(
        passed: true,
        kind: :error,
        name: "test",
        message: "ok"
      )
    end

    it "builds a failing error check" do
      check = described_class.fail("test", "bad")

      expect(check).to have_attributes(
        passed: false,
        kind: :error,
        name: "test",
        message: "bad"
      )
    end

    it "builds a failing warning check" do
      check = described_class.warning(
        "test",
        false,
        "warn msg"
      )

      expect(check).to have_attributes(
        passed: false,
        kind: :warning,
        name: "test",
        message: "warn msg"
      )
    end

    it "builds a passing warning check" do
      check = described_class.warning(
        "test",
        true,
        "ok msg"
      )

      expect(check).to have_attributes(
        passed: true,
        kind: :warning
      )
    end

    it "serializes kind as a lowercase string" do
      aggregate_failures do
        expect(
          described_class.warning(
            "test",
            false,
            "msg"
          ).to_json_hash["kind"]
        ).to eq("warning")
        expect(described_class.fail("test", "msg").to_json_hash["kind"]).to eq("error")
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

  describe ".doctor" do
    let(:mode) { Orn::OutputMode.default }
    let(:project) { make_project(make_bare_project, config_yaml) }
    let(:config_yaml) { "sbx: {}\n" }

    it "includes the git-identity, ssh-auth, and github-secret checks" do
      names = described_class.doctor(
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
      names = described_class.doctor(
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
        names = described_class.doctor(
          mode,
          project.config.sbx,
          project.root
        ).map(&:name)

        expect(names).to include("template", "env:MY_BUILD_ARG")
      end
    end
  end

  describe ".exists? and .try_remove" do
    let(:mode) { Orn::OutputMode.default }

    it "reports a nonexistent sandbox as absent" do
      expect(described_class.exists?(mode, "nonexistent-sandbox")).to be(false)
    end

    it "returns false from try_remove for a nonexistent sandbox" do
      expect(described_class.try_remove(mode, "nonexistent-sandbox")).to be(false)
    end
  end
end
