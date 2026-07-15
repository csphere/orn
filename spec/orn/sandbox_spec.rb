# frozen_string_literal: true

require "socket"
require "tmpdir"
require "fileutils"

RSpec.describe Orn::Sandbox do
  describe Orn::Sandbox::PortMapping do
    it "displays as host:container" do
      expect(described_class.new(host: 3042, container: 3000).to_s).to eq("3042:3000")
    end
  end

  describe ".parse_list_output" do
    it "parses a bare array of sandboxes" do
      json = '[{"name": "sbx-1", "status": "running"}, {"name": "sbx-2", "status": "stopped"}]'

      entries = described_class.parse_list_output(json)

      aggregate_failures do
        expect(entries.length).to eq(2)
        expect(entries[0]).to have_attributes(name: "sbx-1", status: "running")
        expect(entries[1]).to have_attributes(name: "sbx-2", status: "stopped")
      end
    end

    it "parses a {sandboxes: [...]} wrapper object" do
      entries = described_class.parse_list_output('{"sandboxes": [{"name": "sbx-1", "status": "running"}]}')

      expect(entries).to contain_exactly(have_attributes(name: "sbx-1", status: "running"))
    end

    it "returns nothing for an empty array and empty wrapper" do
      aggregate_failures do
        expect(described_class.parse_list_output("[]")).to be_empty
        expect(described_class.parse_list_output('{"sandboxes": []}')).to be_empty
      end
    end

    it "skips entries without a name" do
      json = '[{"status": "running"}, {"name": "sbx-1", "status": "running"}]'

      expect(described_class.parse_list_output(json).map(&:name)).to eq(["sbx-1"])
    end

    it "defaults a missing status to unknown" do
      expect(described_class.parse_list_output('[{"name": "sbx-1"}]').first.status).to eq("unknown")
    end

    it "returns nothing for a wrapper without a sandboxes key" do
      expect(described_class.parse_list_output('{"other": "data"}')).to be_empty
    end

    it "raises on invalid JSON" do
      expect { described_class.parse_list_output("not json") }.to raise_error(Orn::Error, /parse sbx ls/)
    end
  end

  describe ".template_listed?" do
    let(:listing) do
      <<~LISTING
        REPOSITORY                           TAG      IMAGE ID       FLAVOR   CREATED
        docker.io/library/orn-system-rails   latest   0464b62418c6            Less than a minute ago
        registry.example.com/team/base       2026.1   9f3a11aa0b2c            2 days ago
      LISTING
    end

    it "matches a bare repo name against its registry-qualified listing" do
      expect(described_class.template_listed?(listing, "orn-system-rails:latest")).to be(true)
    end

    it "matches a fully qualified template as written" do
      expect(described_class.template_listed?(listing, "registry.example.com/team/base:2026.1")).to be(true)
    end

    it "matches on repo alone when the template has no tag" do
      expect(described_class.template_listed?(listing, "orn-system-rails")).to be(true)
    end

    it "rejects a matching repo with the wrong tag" do
      expect(described_class.template_listed?(listing, "orn-system-rails:v2")).to be(false)
    end

    it "rejects a repo that only shares a suffix" do
      expect(described_class.template_listed?(listing, "system-rails:latest")).to be(false)
    end

    it "rejects anything against an empty listing" do
      expect(described_class.template_listed?("No template images found\n", "orn-system-rails:latest")).to be(false)
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

      expect { described_class.verify_port(port, 1, 0.01) }.not_to raise_error
    ensure
      listener&.close
    end

    it "times out when the port never opens" do
      expect { described_class.verify_port(1, 0.2, 0.05) }.to raise_error(Orn::Error, /not reachable/)
    end
  end

  describe "port persistence" do
    let(:orn_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(orn_dir, true) }

    it "round-trips a single mapping" do
      mappings = [Orn::Sandbox::PortMapping.new(host: 3042, container: 3000)]
      described_class.persist_ports(orn_dir, "my-sbx", mappings)

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "round-trips multiple mappings" do
      mappings = [
        Orn::Sandbox::PortMapping.new(host: 3042, container: 3000),
        Orn::Sandbox::PortMapping.new(host: 6380, container: 6379)
      ]
      described_class.persist_ports(orn_dir, "my-sbx", mappings)

      expect(described_class.read_ports(orn_dir, "my-sbx")).to eq(mappings)
    end

    it "creates the sandbox directory" do
      described_class.persist_ports(orn_dir, "test", [Orn::Sandbox::PortMapping.new(host: 8080, container: 80)])

      expect(File).to exist(File.join(orn_dir, "sandbox", "test.ports"))
    end

    it "raises when reading a missing file" do
      expect { described_class.read_ports(orn_dir, "nonexistent") }.to raise_error(Orn::Error, /Failed to read/)
    end

    it "removes the ports file" do
      described_class.persist_ports(orn_dir, "my-sbx", [Orn::Sandbox::PortMapping.new(host: 3042, container: 3000)])

      described_class.remove_ports_file(orn_dir, "my-sbx")

      expect(File).not_to exist(File.join(orn_dir, "sandbox", "my-sbx.ports"))
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

  describe ".build_create_command" do
    def create_params(**overrides)
      defaults = { name: "my-sbx", agent_type: "claude", worktree_path: "/work/tree", bare_path: "/project/.bare" }
      Orn::Sandbox::CreateParams.new(**defaults, **overrides)
    end

    it "puts the bare path last" do
      args = described_class.build_create_command(create_params)

      expect(args.last).to eq("/project/.bare")
    end

    it "orders the bare path immediately after the worktree path" do
      args = described_class.build_create_command(create_params)

      expect(args.index("/project/.bare")).to eq(args.index("/work/tree") + 1)
    end

    it "orders agent type, worktree, then bare path positionally" do
      args = described_class.build_create_command(
        create_params(template: "my-template:latest", kits: ["/path/to/kit"], cpus: 4, memory: "8g")
      )

      aggregate_failures do
        expect(args.index("claude")).to be < args.index("/work/tree")
        expect(args.index("/work/tree")).to be < args.index("/project/.bare")
        expect(args.last).to eq("/project/.bare")
      end
    end

    it "includes the name and all flags" do
      args = described_class.build_create_command(
        create_params(name: "test-sbx", template: "img:1", kits: ["/kit/a", "/kit/b"], cpus: 2, memory: "4g")
      )

      aggregate_failures do
        expect(args[0..2]).to eq(["create", "--name", "test-sbx"])
        expect(args).to include("-t", "img:1", "--cpus", "2", "-m", "4g")
        expect(args.each_cons(2)).to include(["--kit", "/kit/a"], ["--kit", "/kit/b"])
      end
    end

    it "emits only the required args when minimal" do
      args = described_class.build_create_command(
        create_params(name: "sbx", agent_type: "agent", worktree_path: "/wt", bare_path: "/bare")
      )

      expect(args).to eq(["create", "--name", "sbx", "agent", "/wt", "/bare"])
    end
  end

  describe ".build_exec_command" do
    it "wraps the command in sh -c without env" do
      args = described_class.build_exec_command("my-sbx", "bin/setup", {})

      expect(args).to eq(["exec", "my-sbx", "--", "sh", "-c", "bin/setup"])
    end

    it "prepends sorted env assignments via env(1)" do
      env = { "REDIS_URL" => "redis://localhost:6379", "DATABASE_URL" => "postgres://localhost/db" }

      args = described_class.build_exec_command("my-sbx", "bin/setup", env)

      expect(args).to eq(
        ["exec", "my-sbx", "--", "env",
         "DATABASE_URL=postgres://localhost/db", "REDIS_URL=redis://localhost:6379",
         "sh", "-c", "bin/setup"]
      )
    end
  end

  describe ".build_exec_detached_command" do
    it "adds the -d flag without env" do
      args = described_class.build_exec_detached_command("my-sbx", "bin/start", {})

      expect(args).to eq(["exec", "-d", "my-sbx", "--", "sh", "-c", "bin/start"])
    end

    it "adds the -d flag with env" do
      args = described_class.build_exec_detached_command("my-sbx", "bin/start", { "SECRET" => "s3cr3t" })

      expect(args).to eq(["exec", "-d", "my-sbx", "--", "env", "SECRET=s3cr3t", "sh", "-c", "bin/start"])
    end
  end

  describe Orn::Sandbox::Check do
    it "builds a passing error check" do
      check = described_class.pass("test", "ok")

      expect(check).to have_attributes(passed: true, kind: :error, name: "test", message: "ok")
    end

    it "builds a failing error check" do
      check = described_class.fail("test", "bad")

      expect(check).to have_attributes(passed: false, kind: :error, name: "test", message: "bad")
    end

    it "builds a failing warning check" do
      check = described_class.warning("test", false, "warn msg")

      expect(check).to have_attributes(passed: false, kind: :warning, name: "test", message: "warn msg")
    end

    it "builds a passing warning check" do
      check = described_class.warning("test", true, "ok msg")

      expect(check).to have_attributes(passed: true, kind: :warning)
    end

    it "serializes kind as a lowercase string" do
      aggregate_failures do
        expect(described_class.warning("test", false, "msg").to_json_hash["kind"]).to eq("warning")
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
      config_path = File.join(root, ".bare", "config")
      system(
        GitHelpers::GIT_ISOLATION_ENV, "git", "config", "--file", config_path, key, value,
        out: File::NULL, err: File::NULL
      )
    end

    let(:mode) { Orn::OutputMode.default }

    it "passes when both name and email are set" do
      root = make_bare_project
      set_git_config(root, "user.name", "Test User")
      set_git_config(root, "user.email", "test@example.com")

      check = described_class.git_identity_check(mode, root)

      expect(check).to have_attributes(passed: true, kind: :error, name: "git-identity")
    end

    it "fails and suggests setting the name when it is missing" do
      root = make_bare_project
      set_git_config(root, "user.email", "test@example.com")

      check = described_class.git_identity_check(mode, root)

      aggregate_failures do
        expect(check.passed).to be(false)
        expect(check.message).to include("git config --local user.name")
      end
    end

    it "fails and suggests setting the email when it is missing" do
      root = make_bare_project
      set_git_config(root, "user.name", "Test User")

      check = described_class.git_identity_check(mode, root)

      aggregate_failures do
        expect(check.passed).to be(false)
        expect(check.message).to include("git config --local user.email")
      end
    end

    it "fails when both are missing" do
      check = described_class.git_identity_check(mode, make_bare_project)

      expect(check).to have_attributes(passed: false, kind: :error)
    end
  end

  describe ".ssh_auth_check" do
    it "is a warning-kind check" do
      expect(described_class.ssh_auth_check).to have_attributes(kind: :warning, name: "ssh-auth")
    end
  end

  describe ".github_secret_check" do
    it "is a warning-kind check" do
      expect(described_class.github_secret_check(Orn::OutputMode.default))
        .to have_attributes(kind: :warning, name: "github-secret")
    end
  end

  describe ".doctor" do
    let(:mode) { Orn::OutputMode.default }
    let(:project) { make_project(make_bare_project, config_yaml) }
    let(:config_yaml) { "sbx: {}\n" }

    it "includes the git-identity, ssh-auth, and github-secret checks" do
      names = described_class.doctor(mode, project.config.sbx, project.root).map(&:name)

      expect(names).to include("git-identity", "ssh-auth", "github-secret")
    end

    it "skips the colima check off macOS" do
      names = described_class.doctor(mode, project.config.sbx, project.root).map(&:name)

      if described_class.send(:macos?)
        expect(names).to include("colima")
      else
        expect(names).not_to include("colima")
      end
    end

    context "with a template and build args configured" do
      let(:config_yaml) { "sbx:\n  template: img:1\n  build:\n    build_args: [MY_BUILD_ARG]\n" }

      it "includes the template and per-build-arg env checks" do
        names = described_class.doctor(mode, project.config.sbx, project.root).map(&:name)

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
