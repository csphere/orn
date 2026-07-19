# frozen_string_literal: true

RSpec.describe Orn::Commands::Config::Show do
  subject(:command) { described_class.new(output_mode: Orn::OutputMode.default) }

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

  def empty_global_dir
    register_temp_dir(Dir.mktmpdir("orn-global"))
  end

  # Root symlinks only: one entry with a dest, one without.
  def root_symlink_project
    project_with(<<~YAML)
      symlinks:
        root:
          - source: shared/config
            dest: cfg
          - source: shared/data
    YAML
  end

  describe "#render" do
    it "annotates a project-sourced base branch" do
      info = Orn::Config.info_from(project_with("git:\n  base: develop\n"), nil)

      expect(command.render(info)).to match(/^git:\n  base: develop\s+\(project\)/)
    end

    it "annotates the default base as default-sourced" do
      info = Orn::Config.info_from(empty_project, nil)

      expect(command.render(info)).to match(/  base: main\s+\(default\)/)
    end

    it "annotates a global-sourced layout as a yaml sequence" do
      info = Orn::Config.info_from(empty_project, global_with("tmux:\n  columns:\n    - panes: [\"vim\"]\n"))

      rendered = command.render(info)
      aggregate_failures do
        expect(rendered).to include("tmux:")
        expect(rendered).to include("  columns:")
        expect(rendered).to match(/    - panes: \["vim"\]\s+\(global\)/)
      end
    end

    it "renders a rows layout with nested columns in yaml" do
      info = Orn::Config.info_from(project_with(<<~YAML), nil)
        tmux:
          rows:
            - panes: ["editor"]
            - columns:
                - panes: ["a", "b"]
      YAML

      rendered = command.render(info)
      aggregate_failures do
        expect(rendered).to include("  rows:")
        expect(rendered).to include("    - panes: [\"editor\"]")
        expect(rendered).to include("    - columns:")
        expect(rendered).to include("        - panes: [\"a\", \"b\"]")
      end
    end

    it "renders scalar strings unquoted and empty panes quoted" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      aggregate_failures do
        # scalar strings render plain
        expect(rendered).to match(/  base: main\b/)
        # sequence elements (empty panes) render quoted
        expect(rendered).to include('    - panes: [""]')
        # no `[section]` headers or `key = value` assignments leak through
        expect(rendered).not_to include("[[")
        expect(rendered).not_to include("= ")
      end
    end

    it "renders the tui defaults in yaml" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      aggregate_failures do
        expect(rendered).to include("tui:")
        expect(rendered).to match(/  session: orn\s+\(default\)/)
        expect(rendered).to match(/  scan_depth: 3\s+\(default\)/)
      end
    end

    it "renders a configured session, quoting values that are not plain scalars" do
      info = Orn::Config.info_from(project_with("tmux:\n  session: \"my session\"\n"), nil)

      expect(command.render(info)).to match(/^  session: "my session"\s+\(project\)$/)
    end

    it "renders non-string sequence values without quotes" do
      info = Orn::Config.info_from(empty_project, global_with("tui:\n  scan_roots: [3]\n"))

      expect(command.render(info)).to match(/^  scan_roots: \[3\]\s+\(global\)$/)
    end

    it "marks a missing project config as not found" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      expect(rendered).to match(/^Project config: .* \(not found\)$/)
    end

    it "marks the global config as unavailable when no config dir resolves" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      expect(rendered).to include("Global config:  (unavailable)")
    end

    it "marks a missing global config file as not found" do
      rendered = command.render(Orn::Config.info_from(empty_project, empty_global_dir))

      expect(rendered).to match(%r{^Global config:  .*/default\.yaml \(not found\)$})
    end

    it "omits the symlinks section when base and root are both empty" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      expect(rendered).not_to include("symlinks:")
    end

    it "renders base symlinks without a root list when root is empty" do
      info = Orn::Config.info_from(project_with("symlinks:\n  base: [\"shared/.env\"]\n"), nil)

      rendered = command.render(info)
      aggregate_failures do
        expect(rendered).to match(/^symlinks:\s+\(project\)$/)
        expect(rendered).to include('  base: ["shared/.env"]')
        expect(rendered).not_to include("  root:")
      end
    end

    it "renders root symlinks and omits dest when not set" do
      rendered = command.render(Orn::Config.info_from(root_symlink_project, nil))

      aggregate_failures do
        expect(rendered).not_to match(/^  base: \[/)
        expect(rendered).to include("  root:")
        expect(rendered).to include("    - source: shared/config")
        expect(rendered).to include("      dest: cfg")
        expect(rendered).to include("    - source: shared/data")
        # only the entry with a configured dest gets a dest line
        expect(rendered.scan("dest:").length).to eq(1)
      end
    end
  end

  describe "#json" do
    it "emits the resolved config with per-value sources" do
      info = Orn::Config.info_from(project_with("git:\n  base: develop\n"), nil)

      parsed = JSON.parse(command.json(info))
      expect(parsed["base"]).to eq(
        "value" => "develop",
        "source" => "project"
      )
      expect(parsed["tui"]["scan_depth"]).to eq(
        "value" => 3,
        "source" => "default"
      )
    end

    it "includes the project session when configured" do
      info = Orn::Config.info_from(project_with("tmux:\n  session: work\n"), nil)

      parsed = JSON.parse(command.json(info))
      expect(parsed["session"]).to eq(
        "value" => "work",
        "source" => "project"
      )
    end

    it "emits root symlinks with a null dest when not set" do
      parsed = JSON.parse(command.json(Orn::Config.info_from(root_symlink_project, nil)))

      expect(parsed["symlinks"]["value"]["root"]).to eq(
        [
          {
            "source" => "shared/config",
            "dest" => "cfg"
          },
          {
            "source" => "shared/data",
            "dest" => nil
          }
        ]
      )
    end

    it "emits a rows layout with nested columns and plain panes" do
      info = Orn::Config.info_from(project_with(<<~YAML), nil)
        tmux:
          rows:
            - columns:
                - panes: ["a"]
            - panes: ["editor"]
      YAML

      parsed = JSON.parse(command.json(info))
      expect(parsed["layout"]["value"]).to eq(
        "rows" => [
          { "columns" => [{ "panes" => ["a"] }] },
          { "panes" => ["editor"] }
        ]
      )
    end
  end

  describe "#run" do
    it "prints the rendered config for the discovered project" do
      isolate_global_config
      project = make_bare_project

      expect { Dir.chdir(project) { command.run } }.to output(/git:\n  base: main/).to_stdout
    end

    it "prints the resolved config as json in json mode" do
      isolate_global_config
      project = make_bare_project
      json_command = described_class.new(output_mode: Orn::OutputMode.quiet)

      expect { Dir.chdir(project) { json_command.run } }.to output(/\A\{"project_path":/).to_stdout
    end
  end
end
