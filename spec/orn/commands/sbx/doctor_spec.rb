# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Orn::Commands::Sbx::Doctor do
  let(:command) { described_class.new(output_mode: Orn::OutputMode.default) }

  def project_with(config)
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx-doctor")), config)
  end

  # A bare project the doctor can discover from its root: a git identity in
  # .bare/config, the given sbx config, and isolated global config. Returns
  # the root path for run to discover from.
  def doctor_project_root(config_yaml)
    root = File.realpath(make_bare_project)
    write_bare_git_identity(root)
    File.write(File.join(root, ".orn", "config.yaml"), config_yaml)
    isolate_global_config
    root
  end

  def write_bare_git_identity(root)
    config_path = File.join(
      root,
      ".bare",
      "config"
    )
    git(
      "config",
      "--file",
      config_path,
      "user.name",
      "T"
    )
    git(
      "config",
      "--file",
      config_path,
      "user.email",
      "t@t.com"
    )
  end

  def template_config
    "sbx:\n  template: img:1\n"
  end

  # The git identity probe runs through Cmd, so the fake backend answers the
  # two `git config` lookups with the identity written to .bare/config.
  def script_git_identity(fake, root)
    config_path = File.join(
      root,
      ".bare",
      "config"
    )
    fake.script(["git", "config", "--file", config_path, "user.name"], stdout: "T\n")
    fake.script(["git", "config", "--file", config_path, "user.email"], stdout: "t@t.com\n")
  end

  # On Linux the template-config doctor runs six checks: sbx, docker,
  # git-identity, template, ssh-auth, github-secret (no colima).
  def script_all_passing(fake, root)
    fake.script(%w[which sbx])
    fake.script(%w[which docker])
    script_git_identity(fake, root)
    fake.script(%w[sbx template ls], stdout: "img  1\n")
    fake.script(%w[sbx secret ls], stdout: "github\n")
  end

  def all_passing_stdout
    <<~TEXT
      [ok] sbx: sbx found on PATH
      [ok] docker: docker found on PATH
      [ok] git-identity: Git user.name and user.email configured
      [ok] template: Template 'img:1' found
      [ok] ssh-auth: SSH_AUTH_SOCK is set
      [ok] github-secret: github secret configured
    TEXT
  end

  def mixed_failure_stdout
    <<~TEXT
      [ok] sbx: sbx found on PATH
      [!!] docker: docker not found on PATH
      [ok] git-identity: Git user.name and user.email configured
      [ok] template: Template 'img:1' found
      [--] ssh-auth: SSH_AUTH_SOCK not set; agent will not be able to git push.
          Commits will be available in the host worktree.
      [ok] github-secret: github secret configured

      Some checks failed. Fix the issues above and try again.
    TEXT
  end

  def passing_check(name, message)
    {
      "name" => name,
      "kind" => "error",
      "passed" => true,
      "message" => message
    }
  end

  def passing_warning(name, message)
    passing_check(name, message).merge("kind" => "warning")
  end

  def expected_all_passing_json
    payload = {
      "checks" => [
        passing_check("sbx", "sbx found on PATH"),
        passing_check("docker", "docker found on PATH"),
        passing_check("git-identity", "Git user.name and user.email configured"),
        passing_check("template", "Template 'img:1' found"),
        passing_warning("ssh-auth", "SSH_AUTH_SOCK is set"),
        passing_warning("github-secret", "github secret configured")
      ],
      "all_passed" => true
    }
    "#{JSON.pretty_generate(payload)}\n"
  end

  describe "#run" do
    before { stub_host_os("linux") }

    it "prints an [ok] line per check and no failure footer when everything passes" do
      root = doctor_project_root(template_config)
      ENV["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
      with_fake_cmd do |fake|
        script_all_passing(fake, root)

        expect { Dir.chdir(root) { command.run } }
          .to output(all_passing_stdout).to_stdout
      end
    end

    it "marks failed error checks [!!], failed warnings [--], and prints the failure footer" do
      root = doctor_project_root(template_config)
      ENV.delete("SSH_AUTH_SOCK")
      with_fake_cmd do |fake|
        fake.script(%w[which sbx])
        fake.script(%w[which docker], status: 1)
        script_git_identity(fake, root)
        fake.script(%w[sbx template ls], stdout: "img  1\n")
        fake.script(%w[sbx secret ls], stdout: "github\n")

        expect { Dir.chdir(root) { command.run } }
          .to output(mixed_failure_stdout).to_stdout
      end
    end

    it "prints the checks and all_passed as json" do
      root = doctor_project_root(template_config)
      ENV["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
      json_command = described_class.new(output_mode: Orn::OutputMode.quiet)
      with_fake_cmd do |fake|
        script_all_passing(fake, root)

        expect { Dir.chdir(root) { json_command.run } }
          .to output(expected_all_passing_json).to_stdout
      end
    end
  end

  describe "#run_inner", :real_cmd do
    it "fails without an [sbx] section" do
      project = project_with("git:\n  base: main\n")

      expect { command.run_inner(project) }.to raise_error(Orn::Error, /No sbx section/)
    end

    it "returns the standard checks for a minimal config" do
      stub_host_os("linux")
      project = project_with("sbx:\n  template: img:1\n")

      names = command.run_inner(project).checks.map(&:name)

      aggregate_failures do
        expect(names).to include(
          "sbx",
          "docker",
          "template"
        )
        expect(names).not_to include("colima")
      end
    end

    it "adds an env check per build arg" do
      project = project_with("sbx:\n  template: img:1\n  build:\n    build_args: [MY_BUILD_ARG]\n")

      names = command.run_inner(project).checks.map(&:name)

      expect(names).to include("env:MY_BUILD_ARG")
    end

    it "reports all_passed as the conjunction of every check" do
      project = project_with("sbx:\n  template: img:1\n")

      result = command.run_inner(project)

      expect(result.all_passed).to eq(result.checks.all?(&:passed))
    end
  end

  describe "Result#to_json_hash" do
    it "serializes each check and the overall verdict" do
      failing_check = Orn::Sandbox::Check.fail("docker", "docker not found on PATH")
      result = described_class::Result.new(
        checks: [failing_check],
        all_passed: false
      )

      expect(result.to_json_hash).to eq(
        "checks" => [
          {
            "name" => "docker",
            "kind" => "error",
            "passed" => false,
            "message" => "docker not found on PATH"
          }
        ],
        "all_passed" => false
      )
    end
  end
end
