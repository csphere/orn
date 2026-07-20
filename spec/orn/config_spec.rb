# frozen_string_literal: true

RSpec.describe Orn::Config do
  def project_with(yaml)
    dir = register_temp_dir(Dir.mktmpdir("orn-cfg"))
    FileUtils.mkdir_p(File.join(dir, ".orn"))
    File.write(File.join(dir, ".orn/config.yaml"), yaml)
    dir
  end

  def empty_project
    dir = register_temp_dir(Dir.mktmpdir("orn-cfg"))
    FileUtils.mkdir_p(File.join(dir, ".orn"))
    dir
  end

  def global_with(yaml)
    dir = register_temp_dir(Dir.mktmpdir("orn-global"))
    File.write(File.join(dir, "default.yaml"), yaml)
    dir
  end

  describe ".load_from" do
    context "with no config file" do
      it "uses built-in defaults" do
        config = described_class.load_from(empty_project, nil)

        expect(config.base).to eq("main")
        expect(config.symlinks.base).to be_empty
        expect(config.symlinks.root).to be_empty
        expect(config.layout.columns.length).to eq(2)
      end

      it "defaults the layout to two bare terminals" do
        config = described_class.load_from(empty_project, nil)

        expect(config.layout.columns.map(&:panes)).to eq([[""], [""]])
      end
    end

    context "with a project config" do
      it "reads the base branch and base symlinks" do
        project = project_with(<<~YAML)
          git:
            base: develop
          symlinks:
            base:
              - ".env.local"
              - ".claude/settings.local.json"
        YAML

        config = described_class.load_from(project, nil)

        expect(config.base).to eq("develop")
        expect(config.symlinks.base).to eq([".env.local", ".claude/settings.local.json"])
      end

      it "reads root symlinks, defaulting dest to the source basename" do
        project = project_with(<<~YAML)
          symlinks:
            root:
              - source: "_"
              - source: "_shared/doc"
                dest: "shared_doc"
        YAML

        config = described_class.load_from(project, nil)
        root = config.symlinks.root

        expect(root.map(&:source)).to eq(["_", "_shared/doc"])
        expect(root.map(&:effective_dest)).to eq(%w[_ shared_doc])
      end
    end

    context "with layouts across layers" do
      it "inherits columns from the global config" do
        project = project_with("git:\n  base: develop\n")
        global = global_with(<<~YAML)
          tmux:
            columns:
              - panes: ["vim"]
              - panes: ["claude"]
        YAML

        config = described_class.load_from(project, global)

        expect(config.base).to eq("develop")
        expect(config.layout.columns.map(&:panes)).to eq([["vim"], ["claude"]])
        expect(config.layout_source).to eq(:global)
      end

      it "lets project columns replace global columns" do
        project = project_with(<<~YAML)
          tmux:
            columns:
              - panes: ["rails server"]
        YAML
        global = global_with(<<~YAML)
          tmux:
            columns:
              - panes: ["vim"]
              - panes: ["claude"]
        YAML

        config = described_class.load_from(project, global)

        expect(config.layout.columns.map(&:panes)).to eq([["rails server"]])
        expect(config.layout_source).to eq(:project)
      end

      it "reads a rows layout with panes" do
        project = project_with(<<~YAML)
          tmux:
            rows:
              - panes: ["top-cmd"]
              - panes: ["bottom-cmd"]
        YAML

        config = described_class.load_from(project, nil)

        expect(config.layout.rows?).to be(true)
        expect(config.layout.rows.map(&:panes)).to eq([["top-cmd"], ["bottom-cmd"]])
      end

      it "reads a row with nested columns" do
        project = project_with(<<~YAML)
          tmux:
            rows:
              - panes: ["main-command"]
              - columns:
                  - panes: ["cmd1", "cmd2"]
                  - panes: ["cmd3", "cmd4"]
        YAML

        config = described_class.load_from(project, nil)
        rows = config.layout.rows

        expect(rows[0]).to eq(
          Orn::Config::Row.new(
            panes: ["main-command"],
            columns: []
          )
        )
        expect(rows[1].columns?).to be(true)
        expect(rows[1].columns.map(&:panes)).to eq([%w[cmd1 cmd2], %w[cmd3 cmd4]])
      end

      it "reads a row with the inline columns shorthand" do
        project = project_with(<<~YAML)
          tmux:
            rows:
              - panes: ["1"]
              - columns: [["2"], ["3"]]
        YAML

        config = described_class.load_from(project, nil)
        rows = config.layout.rows

        expect(rows[0].panes).to eq(["1"])
        expect(rows[1].columns.map(&:panes)).to eq([["2"], ["3"]])
      end

      it "rejects a row with both panes and columns, using the default layout" do
        project = project_with(<<~YAML)
          tmux:
            rows:
              - panes: ["editor"]
                columns: [["terminal"], ["logs"]]
        YAML

        config = described_class.load_from(project, nil)

        expect(config.layout.columns.length).to eq(2)
      end

      it "falls back to the default layout when both rows and columns are present" do
        project = project_with(<<~YAML)
          tmux:
            rows:
              - panes: ["top"]
            columns:
              - panes: ["left"]
        YAML

        config = described_class.load_from(project, nil)

        expect(config.layout.columns.length).to eq(2)
        expect(config.layout_source).to eq(:default)
      end

      it "lets project rows override global columns" do
        project = project_with("tmux:\n  rows:\n    - panes: [\"top\"]\n")
        global = global_with("tmux:\n  columns:\n    - panes: [\"vim\"]\n")

        config = described_class.load_from(project, global)

        expect(config.layout.rows.map(&:panes)).to eq([["top"]])
        expect(config.layout_source).to eq(:project)
      end
    end

    context "with a malformed or wrongly-typed config" do
      it "falls back to defaults on a malformed project config" do
        project = project_with("git: [broken\n")

        config = described_class.load_from(project, nil)

        expect(config.base).to eq("main")
        expect(config.layout.columns.length).to eq(2)
      end

      it "still uses global columns when the project config is malformed" do
        project = project_with("git: [broken\n")
        global = global_with("tmux:\n  columns:\n    - panes: [\"vim\"]\n")

        config = described_class.load_from(project, global)

        expect(config.layout.columns.map(&:panes)).to eq([["vim"]])
      end

      it "falls back to defaults when a value has the wrong type" do
        project = project_with("git:\n  base: 42\n")

        config = described_class.load_from(project, nil)

        expect(config.base).to eq("main")
      end
    end

    context "with a session name" do
      it "reads a valid session" do
        project = project_with("tmux:\n  session: work-api\n")

        expect(described_class.load_from(project, nil).session).to eq("work-api")
      end

      it "returns nil when no session is set" do
        project = project_with("git:\n  base: main\n")

        expect(described_class.load_from(project, nil).session).to be_nil
      end

      it "ignores an invalid session name" do
        project = project_with("tmux:\n  session: \"victim:0\"\n")

        expect(described_class.load_from(project, nil).session).to be_nil
      end
    end

    context "with an sbx section" do
      it "returns nil when absent" do
        project = project_with("git:\n  base: main\n")

        expect(described_class.load_from(project, nil).sbx).to be_nil
      end

      it "reads a full sbx config", :aggregate_failures do
        project = project_with(<<~YAML)
          sbx:
            template: "attain-sbx:2026-05-03"
            kit: "sbx/kit"
            cpus: 4
            memory: "4g"
            agent_type: "claude"
            setup: "sbx/setup-db.sh"
            build:
              dockerfile: "sbx/Dockerfile"
              build_args: ["BUNDLE_TOKEN"]
            ports:
              container: 3000
              host_range: [3001, 3100]
            columns:
              - panes: [""]
              - panes: ["sbx run {{sandbox}}"]
        YAML

        sbx = described_class.load_from(project, nil).sbx

        expect(sbx.template).to eq("attain-sbx:2026-05-03")
        expect(sbx.cpus).to eq(4)
        expect(sbx.agent_type).to eq("claude")
        expect(sbx.setup).to eq(["sbx/setup-db.sh"])
        expect(sbx.build.dockerfile).to eq("sbx/Dockerfile")
        expect(sbx.ports.length).to eq(1)
        expect(sbx.ports[0].host_range).to eq([3001, 3100])
        expect(sbx.columns[1].panes).to eq(["sbx run {{sandbox}}"])
      end

      it "reads a minimal agent-only sbx config" do
        project = project_with("sbx:\n  agent_type: claude\n")

        sbx = described_class.load_from(project, nil).sbx

        expect(sbx.agent_type).to eq("claude")
        expect(sbx.template).to be_nil
        expect(sbx.ports).to be_empty
        expect(sbx.all_kits).to be_empty
      end

      it "normalizes a string setup into a list" do
        project = project_with("sbx:\n  agent_type: claude\n  setup: bin/setup\n")

        expect(described_class.load_from(project, nil).sbx.setup).to eq(["bin/setup"])
      end

      it "preserves an array setup" do
        project = project_with(<<~YAML)
          sbx:
            agent_type: claude
            setup:
              - "bundle install"
              - "bin/rails db:prepare"
        YAML

        expect(described_class.load_from(project, nil).sbx.setup).to eq(["bundle install", "bin/rails db:prepare"])
      end

      it "reads env variables" do
        project = project_with(<<~YAML)
          sbx:
            agent_type: claude
            env:
              DATABASE_URL: "postgres://localhost/app"
              REDIS_URL: "redis://localhost:6379"
        YAML

        env = described_class.load_from(project, nil).sbx.env

        expect(env["DATABASE_URL"]).to eq("postgres://localhost/app")
        expect(env["REDIS_URL"]).to eq("redis://localhost:6379")
      end

      it "reads a single port table and an array of port tables" do
        single = project_with("sbx:\n  template: img\n  ports:\n    container: 3000\n    host_range: [3001, 3100]\n")
        array = project_with(<<~YAML)
          sbx:
            template: img
            ports:
              - container: 3000
                host_range: [3001, 3100]
              - container: 6379
                host_range: [6379, 6479]
        YAML

        expect(described_class.load_from(single, nil).sbx.ports.length).to eq(1)
        expect(described_class.load_from(array, nil).sbx.ports.map(&:container)).to eq([3000, 6379])
      end

      it "filters out ports with an invalid host range" do
        project = project_with("sbx:\n  template: img\n  ports:\n    container: 3000\n    host_range: [3100, 3000]\n")

        expect(described_class.load_from(project, nil).sbx.ports).to be_empty
      end

      it "merges the legacy singular kit into kits, de-duplicated" do
        merged = project_with("sbx:\n  agent_type: claude\n  kit: legacy-kit\n  kits: [ruby]\n")
        deduped = project_with("sbx:\n  agent_type: claude\n  kit: ruby\n  kits: [ruby, gh-cli]\n")

        expect(described_class.load_from(merged, nil).sbx.all_kits).to eq(%w[legacy-kit ruby])
        expect(described_class.load_from(deduped, nil).sbx.all_kits).to eq(%w[ruby gh-cli])
      end

      it "warns when setup is neither a string nor a list of strings" do
        project = project_with("sbx:\n  agent_type: claude\n  setup: 42\n")

        config = nil
        expect { config = described_class.load_from(project, nil) }
          .to output(/sbx\.setup must be a string or a list of strings/).to_stderr
        expect(config.sbx).to be_nil
      end

      it "warns when an env value is not a string" do
        project = project_with("sbx:\n  agent_type: claude\n  env:\n    PORT: 3000\n")

        config = nil
        expect { config = described_class.load_from(project, nil) }
          .to output(/sbx\.env must be a mapping of strings to strings/).to_stderr
        expect(config.sbx).to be_nil
      end

      it "warns when ports is neither a mapping nor a list" do
        project = project_with("sbx:\n  template: img\n  ports: \"3000\"\n")

        config = nil
        expect { config = described_class.load_from(project, nil) }
          .to output(/sbx\.ports must be a mapping or a list of mappings/).to_stderr
        expect(config.sbx).to be_nil
      end

      it "tolerates and ignores unknown top-level keys" do
        project = project_with("orn_version: \"0.7.0\"\ngit:\n  base: develop\n")

        expect(described_class.load_from(project, nil).base).to eq("develop")
      end
    end
  end

  describe "#require_sbx!" do
    it "returns the sbx config when present" do
      project = project_with("sbx:\n  agent_type: claude\n")

      expect(described_class.load_from(project, nil).require_sbx!).not_to be_nil
    end

    it "raises when the sbx section is absent" do
      project = project_with("git:\n  base: main\n")

      expect { described_class.load_from(project, nil).require_sbx! }
        .to raise_error(Orn::Error, /No sbx section/)
    end
  end

  describe "#effective_sbx_layout" do
    it "uses the sbx columns when present, marked project-sourced" do
      project = project_with(<<~YAML)
        sbx:
          template: img
          columns:
            - panes: [""]
            - panes: ["sbx run {{sandbox}}"]
      YAML

      layout, source = described_class.load_from(project, nil).effective_sbx_layout

      expect(source).to eq(:project)
      expect(layout.columns.length).to eq(2)
    end

    it "falls back to the main layout and its source" do
      project = project_with("tmux:\n  columns:\n    - panes: [\"vim\"]\n")

      layout, source = described_class.load_from(project, nil).effective_sbx_layout

      expect(source).to eq(:project)
      expect(layout.columns.map(&:panes)).to eq([["vim"]])
    end
  end

  describe ".write_session" do
    it "creates the session key, keeping other values" do
      project = project_with("git:\n  base: main\n")

      described_class.write_session(project, "work-api")

      config = described_class.load_from(project, nil)
      expect(config.session).to eq("work-api")
      expect(config.base).to eq("main")
    end

    it "updates an existing session and writes to an empty file" do
      existing = project_with("tmux:\n  session: old-name\n")
      empty = project_with("")

      described_class.write_session(existing, "new-name")
      described_class.write_session(empty, "fresh")

      expect(described_class.load_from(existing, nil).session).to eq("new-name")
      expect(described_class.load_from(empty, nil).session).to eq("fresh")
    end

    it "rejects an invalid session name" do
      project = project_with("")

      expect { described_class.write_session(project, "victim:0") }.to raise_error(Orn::Error)
    end

    it "creates the config file when none exists" do
      project = empty_project

      described_class.write_session(project, "fresh-start")

      expect(described_class.load_from(project, nil).session).to eq("fresh-start")
    end

    it "refuses to rewrite a file that does not parse, keeping its content" do
      broken_yaml = "git: [broken\n"
      project = project_with(broken_yaml)
      config_path = File.join(
        project,
        ".orn",
        "config.yaml"
      )

      expect { described_class.write_session(project, "recovered") }
        .to raise_error(Orn::Error, /does not parse as a YAML mapping/)

      expect(File.read(config_path)).to eq(broken_yaml)
    end

    it "refuses to rewrite a file whose content is not a mapping" do
      project = project_with("just a string\n")

      expect { described_class.write_session(project, "recovered") }
        .to raise_error(Orn::Error, /does not parse as a YAML mapping/)
    end
  end

  describe ".info_from" do
    it "reports defaults and their sources when there is no config" do
      info = described_class.info_from(empty_project, nil)

      expect(info.project_exists).to be(false)
      expect(info.base.value).to eq("main")
      expect(info.base.source).to eq(:default)
      expect(info.session).to be_nil
      expect(info.layout.source).to eq(:default)
    end

    it "reports project-sourced values" do
      project = project_with("git:\n  base: main\nsymlinks:\n  base: [\".env\"]\n")

      info = described_class.info_from(project, nil)

      expect(info.project_exists).to be(true)
      expect(info.base.source).to eq(:project)
      expect(info.symlinks.value.base).to eq([".env"])
      expect(info.symlinks.source).to eq(:project)
      expect(info.layout.source).to eq(:default)
    end

    it "attributes a global-sourced layout while base stays project-sourced" do
      project = project_with("git:\n  base: main\n")
      global = global_with("tmux:\n  columns:\n    - panes: [\"vim\"]\n    - panes: [\"claude\"]\n")

      info = described_class.info_from(project, global)

      expect(info.global_exists).to be(true)
      expect(info.base.source).to eq(:project)
      expect(info.layout.value.columns.length).to eq(2)
      expect(info.layout.source).to eq(:global)
    end

    it "reports tui defaults when there is no global config" do
      info = described_class.info_from(empty_project, nil)

      expect(info.tui.session.value).to eq("orn")
      expect(info.tui.session.source).to eq(:default)
      expect(info.tui.scan_depth.value).to eq(3)
    end

    it "reports tui values from the global config" do
      project = empty_project
      global = global_with("tui:\n  session: dev\n  scan_roots: [\"/home/user/dev\"]\n  scan_depth: 5\n")

      info = described_class.info_from(project, global)

      expect(info.tui.session.value).to eq("dev")
      expect(info.tui.session.source).to eq(:global)
      expect(info.tui.scan_roots.value).to eq(["/home/user/dev"])
      expect(info.tui.scan_depth.value).to eq(5)
    end
  end
end
