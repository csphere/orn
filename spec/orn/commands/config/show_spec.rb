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

    it "marks a missing project config as not found" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      expect(rendered).to include("(not found)")
    end
  end

  describe "#json" do
    it "emits the resolved config with per-value sources" do
      info = Orn::Config.info_from(project_with("git:\n  base: develop\n"), nil)

      parsed = JSON.parse(command.json(info))
      expect(parsed["base"]).to eq("value" => "develop", "source" => "project")
      expect(parsed["tui"]["scan_depth"]).to eq("value" => 3, "source" => "default")
    end
  end
end
