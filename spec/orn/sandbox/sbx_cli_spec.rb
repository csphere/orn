# frozen_string_literal: true

RSpec.describe Orn::Sandbox::SbxCli do
  let(:mode) { Orn::OutputMode.default }

  describe ".build_create_command" do
    def create_params(**overrides)
      defaults = {
        name: "my-sbx",
        agent_type: "claude",
        worktree_path: "/work/tree",
        bare_path: "/project/.bare"
      }
      Orn::Sandbox::CreateParams.new(
        **defaults,
        **overrides
      )
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
        create_params(
          template: "my-template:latest",
          kits: ["/path/to/kit"],
          cpus: 4,
          memory: "8g"
        )
      )

      aggregate_failures do
        expect(args.index("claude")).to be < args.index("/work/tree")
        expect(args.index("/work/tree")).to be < args.index("/project/.bare")
        expect(args.last).to eq("/project/.bare")
      end
    end

    it "includes the name and all flags" do
      args = described_class.build_create_command(
        create_params(
          name: "test-sbx",
          template: "img:1",
          kits: ["/kit/a", "/kit/b"],
          cpus: 2,
          memory: "4g"
        )
      )

      aggregate_failures do
        expect(args[0..2]).to eq(["create", "--name", "test-sbx"])
        expect(args).to include(
          "-t",
          "img:1",
          "--cpus",
          "2",
          "-m",
          "4g"
        )
        expect(args.each_cons(2)).to include(["--kit", "/kit/a"], ["--kit", "/kit/b"])
      end
    end

    it "emits only the required args when minimal" do
      args = described_class.build_create_command(
        create_params(
          name: "sbx",
          agent_type: "agent",
          worktree_path: "/wt",
          bare_path: "/bare"
        )
      )

      expect(args).to eq(["create", "--name", "sbx", "agent", "/wt", "/bare"])
    end
  end

  describe ".create" do
    let(:params) do
      Orn::Sandbox::CreateParams.new(
        name: "my-sbx",
        agent_type: "claude",
        worktree_path: "/work/tree",
        bare_path: "/project/.bare"
      )
    end

    let(:create_argv) { ["sbx", "create", "--name", "my-sbx", "claude", "/work/tree", "/project/.bare"] }

    it "raises when sbx create exits nonzero" do
      with_fake_cmd do |fake|
        fake.script(
          create_argv,
          stderr: "template not found",
          status: 1
        )

        expect { described_class.create(mode, params) }
          .to raise_error(Orn::Error, /template not found/)
      end
    end

    it "raises command not found when the sbx binary is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(create_argv)

        expect { described_class.create(mode, params) }
          .to raise_error(Orn::Error, /Failed to run sbx: command not found/)
      end
    end
  end

  describe ".build_exec_command" do
    it "wraps the command in sh -c without env" do
      args = described_class.build_exec_command(
        "my-sbx",
        "bin/setup",
        {}
      )

      expect(args).to eq(["exec", "my-sbx", "--", "sh", "-c", "bin/setup"])
    end

    it "prepends sorted env assignments via env(1)" do
      env = {
        "REDIS_URL" => "redis://localhost:6379",
        "DATABASE_URL" => "postgres://localhost/db"
      }

      args = described_class.build_exec_command(
        "my-sbx",
        "bin/setup",
        env
      )

      expect(args).to eq(
        [
          "exec",
          "my-sbx",
          "--",
          "env",
          "DATABASE_URL=postgres://localhost/db",
          "REDIS_URL=redis://localhost:6379",
          "sh",
          "-c",
          "bin/setup"
        ]
      )
    end
  end

  describe ".build_exec_detached_command" do
    it "adds the -d flag without env" do
      args = described_class.build_exec_detached_command(
        "my-sbx",
        "bin/start",
        {}
      )

      expect(args).to eq(["exec", "-d", "my-sbx", "--", "sh", "-c", "bin/start"])
    end

    it "adds the -d flag with env" do
      args = described_class.build_exec_detached_command(
        "my-sbx",
        "bin/start",
        { "SECRET" => "s3cr3t" }
      )

      expect(args).to eq(["exec", "-d", "my-sbx", "--", "env", "SECRET=s3cr3t", "sh", "-c", "bin/start"])
    end
  end

  describe ".list" do
    it "sends sbx ls --json and parses the listing" do
      with_fake_cmd do |fake|
        fake.script(
          ["sbx", "ls", "--json"],
          stdout: '[{"name": "sbx-1", "status": "running"}]'
        )

        entries = described_class.list(mode)

        aggregate_failures do
          expect(fake.invocations).to eq([["sbx", "ls", "--json"]])
          expect(entries).to contain_exactly(
            have_attributes(
              name: "sbx-1",
              status: "running"
            )
          )
        end
      end
    end

    it "treats a nonzero exit as an empty list" do
      with_fake_cmd do |fake|
        fake.script(
          ["sbx", "ls", "--json"],
          stderr: "daemon not running",
          status: 1
        )

        expect(described_class.list(mode)).to be_empty
      end
    end
  end

  describe ".parse_list_output" do
    it "parses a bare array of sandboxes" do
      json = '[{"name": "sbx-1", "status": "running"}, {"name": "sbx-2", "status": "stopped"}]'

      entries = described_class.parse_list_output(json)

      aggregate_failures do
        expect(entries.length).to eq(2)
        expect(entries[0]).to have_attributes(
          name: "sbx-1",
          status: "running"
        )
        expect(entries[1]).to have_attributes(
          name: "sbx-2",
          status: "stopped"
        )
      end
    end

    it "parses a {sandboxes: [...]} wrapper object" do
      entries = described_class.parse_list_output('{"sandboxes": [{"name": "sbx-1", "status": "running"}]}')

      expect(entries).to contain_exactly(
        have_attributes(
          name: "sbx-1",
          status: "running"
        )
      )
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

  describe ".exists?" do
    it "reports an inspectable sandbox as present" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx inspect my-sbx])

        expect(described_class.exists?(mode, "my-sbx")).to be(true)
      end
    end

    it "reports a failing inspect as absent" do
      with_fake_cmd do |fake|
        fake.script(
          %w[sbx inspect my-sbx],
          stderr: "no such sandbox",
          status: 1
        )

        expect(described_class.exists?(mode, "my-sbx")).to be(false)
      end
    end
  end

  describe ".try_remove" do
    it "removes with --force and reports success" do
      with_fake_cmd do |fake|
        fake.script(["sbx", "rm", "--force", "my-sbx"])

        removed = described_class.try_remove(mode, "my-sbx")

        aggregate_failures do
          expect(removed).to be(true)
          expect(fake.invocations).to eq([["sbx", "rm", "--force", "my-sbx"]])
        end
      end
    end

    it "returns false when removal fails" do
      with_fake_cmd do |fake|
        fake.script(
          ["sbx", "rm", "--force", "my-sbx"],
          stderr: "no such sandbox",
          status: 1
        )

        expect(described_class.try_remove(mode, "my-sbx")).to be(false)
      end
    end
  end

  describe ".publish_port" do
    it "publishes host:container via sbx ports" do
      with_fake_cmd do |fake|
        fake.script(["sbx", "ports", "my-sbx", "--publish", "3042:3000"])

        described_class.publish_port(
          mode,
          "my-sbx",
          3042,
          3000
        )

        expect(fake.invocations).to eq([["sbx", "ports", "my-sbx", "--publish", "3042:3000"]])
      end
    end
  end

  describe ".template_exists?" do
    let(:listing) do
      <<~LISTING
        REPOSITORY                           TAG      IMAGE ID       FLAVOR   CREATED
        docker.io/library/orn-system-rails   latest   0464b62418c6            Less than a minute ago
      LISTING
    end

    it "finds a listed template" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx template ls], stdout: listing)

        expect(described_class.template_exists?(mode, "orn-system-rails:latest")).to be(true)
      end
    end

    it "reports a template missing from the listing as absent" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx template ls], stdout: listing)

        expect(described_class.template_exists?(mode, "other-template:latest")).to be(false)
      end
    end

    it "reports the template as absent when the listing fails" do
      with_fake_cmd do |fake|
        fake.script(
          %w[sbx template ls],
          stderr: "daemon not running",
          status: 1
        )

        expect(described_class.template_exists?(mode, "orn-system-rails:latest")).to be(false)
      end
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

  describe ".docker_build" do
    it "sends build args as --build-arg name=value pairs" do
      argv = [
        "docker",
        "build",
        "-f",
        "Dockerfile",
        "-t",
        "img:1",
        "--build-arg",
        "TOKEN=t0k3n",
        "."
      ]

      with_fake_cmd do |fake|
        fake.script(argv)

        described_class.docker_build(
          mode,
          "Dockerfile",
          "img:1",
          { "TOKEN" => "t0k3n" },
          "."
        )

        expect(fake.invocations).to eq([argv])
      end
    end

    it "raises when docker build exits nonzero" do
      with_fake_cmd do |fake|
        fake.script(
          ["docker", "build", "-f", "Dockerfile", "-t", "img:1", "."],
          stderr: "no such file",
          status: 1
        )

        expect do
          described_class.docker_build(
            mode,
            "Dockerfile",
            "img:1",
            {},
            "."
          )
        end.to raise_error(Orn::Error, /docker failed: no such file/)
      end
    end
  end

  describe ".secret_listed?" do
    it "finds a listed secret" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx secret ls], stdout: "NAME\ngithub\n")

        expect(described_class.secret_listed?(mode, "github")).to be(true)
      end
    end

    it "reports an unlisted secret as absent" do
      with_fake_cmd do |fake|
        fake.script(%w[sbx secret ls], stdout: "NAME\nother\n")

        expect(described_class.secret_listed?(mode, "github")).to be(false)
      end
    end

    it "reports the secret as absent when the listing fails" do
      with_fake_cmd do |fake|
        fake.script(
          %w[sbx secret ls],
          stderr: "not logged in",
          status: 1
        )

        expect(described_class.secret_listed?(mode, "github")).to be(false)
      end
    end
  end

  describe ".colima_status" do
    it "reports running with the arch from the status JSON" do
      with_fake_cmd do |fake|
        fake.script(
          ["colima", "status", "--json"],
          stdout: '{"arch": "aarch64"}'
        )

        expect(described_class.colima_status(mode)).to have_attributes(
          running: true,
          arch: "aarch64"
        )
      end
    end

    it "reports not running on a nonzero exit" do
      with_fake_cmd do |fake|
        fake.script(
          ["colima", "status", "--json"],
          stderr: "colima is not running",
          status: 1
        )

        expect(described_class.colima_status(mode)).to have_attributes(
          running: false,
          arch: nil
        )
      end
    end

    it "reports not running when the colima binary is missing" do
      with_fake_cmd do |fake|
        fake.script_missing(["colima", "status", "--json"])

        expect(described_class.colima_status(mode)).to have_attributes(
          running: false,
          arch: nil
        )
      end
    end
  end
end
