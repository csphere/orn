# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Orn::Commands::Sbx::Remove do
  let(:command) { described_class.new(output_mode: Orn::OutputMode.default) }

  # A bare project with session name "proj" configured, so branch "feat" maps
  # to sandbox "proj-feat". Global config is isolated so `run`'s project
  # discovery stays hermetic.
  def sandbox_project
    root = File.realpath(make_bare_project)
    File.write(File.join(root, ".orn", "config.yaml"), "tmux:\n  session: proj\n")
    isolate_global_config
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  def persist_ports(project)
    Orn::Sandbox::Ports.persist_ports(
      File.join(project.root, ".orn"),
      "proj-feat",
      [
        Orn::Sandbox::PortMapping.new(
          host: 3042,
          container: 3000
        )
      ]
    )
  end

  def ports_file_path(project)
    File.join(
      project.root,
      ".orn",
      "sandbox",
      "proj-feat.ports"
    )
  end

  def remove_argv
    %w[sbx rm --force proj-feat]
  end

  def script_remove(fake, status:)
    fake.script(%w[which sbx])
    fake.script(remove_argv, status: status)
  end

  describe "#run_inner" do
    it "removes the sandbox and its ports file when the sandbox exists" do
      project = sandbox_project
      persist_ports(project)
      with_fake_cmd do |fake|
        script_remove(fake, status: 0)

        result = nil
        expect { result = command.run_inner(project, "feat") }
          .to output("Removed sandbox 'proj-feat'\n").to_stderr

        expect(result).to eq(
          described_class::Result.new(
            name: "proj-feat",
            branch: "feat",
            removed: true
          )
        )
        expect(fake.invocations).to eq(
          [
            %w[which sbx],
            remove_argv
          ]
        )
        expect(File).not_to exist(ports_file_path(project))
      end
    end

    it "still deletes the ports file when no sandbox exists" do
      project = sandbox_project
      persist_ports(project)
      with_fake_cmd do |fake|
        script_remove(fake, status: 1)

        result = nil
        expect { result = command.run_inner(project, "feat") }
          .not_to output.to_stderr

        expect(result.removed).to be(false)
        expect(File).not_to exist(ports_file_path(project))
      end
    end
  end

  describe "#run" do
    it "prints the removed line when the sandbox existed" do
      project = sandbox_project
      with_fake_cmd do |fake|
        script_remove(fake, status: 0)

        expect { Dir.chdir(project.root) { command.run("feat") } }
          .to output("Removed sandbox: proj-feat\n").to_stdout
          .and output("Removed sandbox 'proj-feat'\n").to_stderr
      end
    end

    it "prints the not-found line when no sandbox existed" do
      project = sandbox_project
      with_fake_cmd do |fake|
        script_remove(fake, status: 1)

        expect { Dir.chdir(project.root) { command.run("feat") } }
          .to output("No sandbox found for 'feat'\n").to_stdout
      end
    end

    it "prints json instead of the human line in json mode" do
      project = sandbox_project
      json_command = described_class.new(output_mode: Orn::OutputMode.quiet)
      expected_payload = {
        "name" => "proj-feat",
        "branch" => "feat",
        "removed" => true
      }
      with_fake_cmd do |fake|
        script_remove(fake, status: 0)

        expect { Dir.chdir(project.root) { json_command.run("feat") } }
          .to output("#{JSON.pretty_generate(expected_payload)}\n").to_stdout
      end
    end

    it "rejects an invalid branch name before touching the sandbox" do
      expect { command.run("bad name") }
        .to raise_error(Orn::Error, "Invalid branch name 'bad name': contains space")
    end
  end

  describe "Result#to_json_hash" do
    it "maps the three fields to string keys" do
      result = described_class::Result.new(
        name: "proj-feat",
        branch: "feat",
        removed: false
      )

      expect(result.to_json_hash).to eq(
        "name" => "proj-feat",
        "branch" => "feat",
        "removed" => false
      )
    end
  end
end
