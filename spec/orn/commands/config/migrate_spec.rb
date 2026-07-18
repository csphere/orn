# frozen_string_literal: true

RSpec.describe Orn::Commands::Config::Migrate do
  def project_with_config(yaml)
    project = make_bare_project
    File.write(
      File.join(
        project,
        ".orn",
        "config.yaml"
      ),
      yaml
    )
    project
  end

  def command(dry_run: false, global_only: false, project_only: true, output_mode: Orn::OutputMode.quiet)
    described_class.new(
      output_mode: output_mode,
      dry_run: dry_run,
      global_only: global_only,
      project_only: project_only
    )
  end

  describe "#run" do
    it "stamps orn_version and backs up the project config" do
      project = project_with_config("git:\n  base: main\n")

      Dir.chdir(project) { command.run }

      config_path = File.join(
        project,
        ".orn",
        "config.yaml"
      )
      aggregate_failures do
        expect(File.read(config_path)).to include("orn_version")
        expect(File).to exist("#{config_path}.bak.1")
      end
    end

    it "writes nothing on a dry run" do
      project = project_with_config("git:\n  base: main\n")
      config_path = File.join(
        project,
        ".orn",
        "config.yaml"
      )
      original = File.read(config_path)

      Dir.chdir(project) { command(dry_run: true).run }

      expect(File.read(config_path)).to eq(original)
    end

    it "reports a missing project config to stderr" do
      project = make_bare_project

      expect { Dir.chdir(project) { command(output_mode: Orn::OutputMode.default).run } }
        .to output(/project config not found/).to_stderr
    end

    it "emits the migrated files as json in json mode" do
      project = project_with_config("git:\n  base: main\n")

      expect { Dir.chdir(project) { command.run } }.to output(/"files"/).to_stdout
    end
  end

  describe "#targets" do
    it "returns only the project config with project_only" do
      expect(command(project_only: true).targets("/proj")).to eq([["project", "/proj/.orn/config.yaml"]])
    end

    it "returns only the global config with global_only" do
      ENV["XDG_CONFIG_HOME"] = "/xdg"

      expect(
        command(
          global_only: true,
          project_only: false
        ).targets("/proj")
      )
        .to eq([["global", "/xdg/orn/default.yaml"]])
    end

    it "returns both project and global by default" do
      ENV["XDG_CONFIG_HOME"] = "/xdg"

      expect(command(project_only: false).targets("/proj"))
        .to eq([["project", "/proj/.orn/config.yaml"], ["global", "/xdg/orn/default.yaml"]])
    end
  end
end
