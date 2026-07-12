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

      expect(command.render(info)).to match(/\[git\] base = "develop"\s+\(project\)/)
    end

    it "annotates the default base as default-sourced" do
      info = Orn::Config.info_from(empty_project, nil)

      expect(command.render(info)).to match(/\[git\] base = "main"\s+\(default\)/)
    end

    it "annotates a global-sourced layout" do
      info = Orn::Config.info_from(empty_project, global_with("tmux:\n  columns:\n    - panes: [\"vim\"]\n"))

      rendered = command.render(info)
      expect(rendered).to match(/\[\[tmux\.columns\]\]\s+\(global\)/)
      expect(rendered).to include('panes = ["vim"]')
    end

    it "renders a rows layout with nested columns" do
      info = Orn::Config.info_from(project_with(<<~YAML), nil)
        tmux:
          rows:
            - panes: ["editor"]
            - columns:
                - panes: ["a", "b"]
      YAML

      rendered = command.render(info)
      expect(rendered).to include("[[tmux.rows]]")
      expect(rendered).to include("[[tmux.rows.columns]]")
      expect(rendered).to include('panes = ["a", "b"]')
    end

    it "renders the tui defaults" do
      rendered = command.render(Orn::Config.info_from(empty_project, nil))

      expect(rendered).to match(/\[tui\] session = "orn"\s+\(default\)/)
      expect(rendered).to match(/\[tui\] scan_depth = 3\s+\(default\)/)
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
