# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Orn::Commands::Sbx::Build do
  let(:command) { described_class.new(output_mode: Orn::OutputMode.default) }

  def project_with(config)
    make_project(register_temp_dir(Dir.mktmpdir("orn-sbx-build")), config)
  end

  # A bare project the command can discover from its root, with isolated
  # global config, data, and tmp dirs so trust approvals and the template
  # tar stay inside the example's temp env.
  def buildable_project(config_yaml)
    root = File.realpath(make_bare_project)
    File.write(File.join(root, ".orn", "config.yaml"), config_yaml)
    isolate_global_config
    ENV["XDG_DATA_HOME"] = register_temp_dir(Dir.mktmpdir("orn-sbx-build-data"))
    ENV["TMPDIR"] = register_temp_dir(Dir.mktmpdir("orn-sbx-build-tmp"))
    Orn::Git::Project.new(
      root: root,
      config: Orn::Config.load_from(root, nil)
    )
  end

  # Records the sbx-command approval the way an earlier interactive run would
  # have, so the trust check passes without a prompt.
  def approve_sbx_commands(project)
    approved_dir = File.join(
      ENV.fetch("XDG_DATA_HOME"),
      "orn",
      "approved"
    )
    approval_path = File.join(approved_dir, "sbx-#{Orn::Trust.project_id(project.root)}")
    Orn::Trust.save_approval(approval_path, Orn::Trust.sbx_fingerprint(project.config.sbx))
  end

  def write_dockerfile(project, relative_path)
    dockerfile_path = File.join(project.root, relative_path)
    FileUtils.mkdir_p(File.dirname(dockerfile_path))
    File.write(dockerfile_path, "FROM scratch\n")
  end

  # --- Config fixtures ---

  def build_args_config
    <<~YAML
      sbx:
        template: img:1
        build:
          dockerfile: docker/Dockerfile
          build_args: [ORN_SPEC_GIT_TOKEN, ORN_SPEC_NPM_TOKEN]
    YAML
  end

  def plain_build_config
    <<~YAML
      sbx:
        template: img:1
        build: {}
    YAML
  end

  # --- Command lines ---

  # The template tar goes under Dir.tmpdir (the per-example TMPDIR), named
  # after the tag with ":" sanitized to "-".
  def template_tar_path
    File.join(Dir.tmpdir, "orn-img-1.tar")
  end

  def prerequisite_argvs
    [
      %w[which docker],
      %w[which sbx]
    ]
  end

  def docker_build_argv(dockerfile, *build_arg_flags)
    [
      "docker",
      "build",
      "-f",
      dockerfile,
      "-t",
      "img:1",
      *build_arg_flags,
      "."
    ]
  end

  def docker_save_argv
    [
      "docker",
      "save",
      "-o",
      template_tar_path,
      "img:1"
    ]
  end

  def template_load_argv
    ["sbx", "template", "load", template_tar_path]
  end

  def script_prerequisites(fake)
    fake.script(%w[which docker])
    fake.script(%w[which sbx])
  end

  def script_successful_build(fake, build_argv)
    script_prerequisites(fake)
    fake.script(build_argv)
    fake.script(docker_save_argv)
    fake.script(template_load_argv)
  end

  describe "#run" do
    it "builds the image with build args from the environment and prints the result" do
      project = buildable_project(build_args_config)
      approve_sbx_commands(project)
      ENV["ORN_SPEC_GIT_TOKEN"] = "tok-a"
      ENV["ORN_SPEC_NPM_TOKEN"] = "tok-b"
      write_dockerfile(project, "docker/Dockerfile")
      build_argv = docker_build_argv(
        "docker/Dockerfile",
        "--build-arg",
        "ORN_SPEC_GIT_TOKEN=tok-a",
        "--build-arg",
        "ORN_SPEC_NPM_TOKEN=tok-b"
      )
      with_fake_cmd do |fake|
        script_successful_build(fake, build_argv)

        expect { Dir.chdir(project.root) { command.run } }
          .to output("Built template: img:1\nDockerfile: docker/Dockerfile\n").to_stdout
          .and output(
            %r{Building template 'img:1' from docker/Dockerfile \(build args: ORN_SPEC_GIT_TOKEN, ORN_SPEC_NPM_TOKEN\)}
          ).to_stderr

        expect(fake.invocations).to eq(
          [
            *prerequisite_argvs,
            build_argv,
            docker_save_argv,
            template_load_argv
          ]
        )
      end
    end

    it "defaults the dockerfile, announces without build args, and removes the template tar" do
      project = buildable_project(plain_build_config)
      approve_sbx_commands(project)
      write_dockerfile(project, "Dockerfile")
      with_fake_cmd do |fake|
        script_successful_build(fake, docker_build_argv("Dockerfile"))
        File.write(template_tar_path, "loaded tar")

        expect { Dir.chdir(project.root) { command.run } }
          .to output("Built template: img:1\nDockerfile: Dockerfile\n").to_stdout
          .and output(/Building template 'img:1' from Dockerfile\.\.\./).to_stderr

        expect(File).not_to exist(template_tar_path)
      end
    end

    it "prints json and keeps stderr free of status text" do
      project = buildable_project(plain_build_config)
      approve_sbx_commands(project)
      json_command = described_class.new(output_mode: Orn::OutputMode.quiet)
      write_dockerfile(project, "Dockerfile")
      expected_payload = {
        "template" => "img:1",
        "dockerfile" => "Dockerfile"
      }
      with_fake_cmd do |fake|
        script_successful_build(fake, docker_build_argv("Dockerfile"))

        expect { Dir.chdir(project.root) { json_command.run } }
          .to output("#{JSON.pretty_generate(expected_payload)}\n").to_stdout
          .and output("").to_stderr
      end
    end

    it "fails when a build arg is not set in the environment" do
      project = buildable_project(build_args_config)
      approve_sbx_commands(project)
      ENV["ORN_SPEC_GIT_TOKEN"] = "tok-a"
      ENV.delete("ORN_SPEC_NPM_TOKEN")
      write_dockerfile(project, "docker/Dockerfile")
      with_fake_cmd do |fake|
        script_prerequisites(fake)

        expect do
          expect { Dir.chdir(project.root) { command.run } }
            .to raise_error(Orn::Error, "Build arg ORN_SPEC_NPM_TOKEN not set in environment")
        end.to output(/Building template/).to_stderr
      end
    end

    it "removes the partial tar and raises when docker save fails" do
      project = buildable_project(plain_build_config)
      approve_sbx_commands(project)
      write_dockerfile(project, "Dockerfile")
      with_fake_cmd do |fake|
        script_prerequisites(fake)
        fake.script(docker_build_argv("Dockerfile"))
        fake.script(
          docker_save_argv,
          status: 1,
          stderr: "save exploded"
        )
        File.write(template_tar_path, "partial tar")

        expect do
          expect { Dir.chdir(project.root) { command.run } }
            .to raise_error(Orn::Error, "docker failed: save exploded")
        end.to output(/Building template/).to_stderr

        expect(File).not_to exist(template_tar_path)
      end
    end
  end

  describe "#run_inner" do
    it "fails without an [sbx] section" do
      project = project_with("git:\n  base: main\n")

      expect { command.run_inner(project) }.to raise_error(Orn::Error, /No sbx section/)
    end

    it "fails without an [sbx.build] section" do
      project = project_with("sbx:\n  template: img:1\n")

      expect { command.run_inner(project) }.to raise_error(Orn::Error, /No sbx\.build section/)
    end

    it "fails without a template" do
      project = project_with("sbx:\n  build:\n    dockerfile: Dockerfile\n")

      expect { command.run_inner(project) }.to raise_error(Orn::Error, /template/)
    end

    it "fails when the dockerfile is missing" do
      project = project_with("sbx:\n  template: img:1\n  build:\n    dockerfile: nonexistent/Dockerfile\n")

      expect { command.run_inner(project) }.to raise_error(Orn::Error, /Dockerfile not found/)
    end
  end
end
