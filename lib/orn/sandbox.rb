# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Orn
  # Shared home for sandbox (Docker Sandboxes microVM) work: the value types, the
  # required-tool checks, and the multi-step flows (setup commands, template
  # build). Single sbx/docker/colima invocations live in the SbxCli adapter,
  # port handling in Ports, and environment checks in Doctor; commands call
  # those modules directly.
  module Sandbox
    # A host-to-container port mapping, displayed as `host:container`.
    PortMapping = Data.define(:host, :container) do
      def to_s
        "#{host}:#{container}"
      end

      # String-keyed hash for `--json` output.
      def to_json_hash
        {
          "host" => host,
          "container" => container
        }
      end
    end

    # A sandbox name and status as reported by `sbx ls`.
    SandboxEntry = Data.define(:name, :status)

    # Inputs for the `sbx create` invocation. `worktree_path` and `bare_path`
    # are positional args after `agent_type`, in that order. `kits` defaults to
    # empty; `template`/`cpus`/`memory` are optional.
    CreateParams = Data.define(
      :name,
      :template,
      :kits,
      :cpus,
      :memory,
      :agent_type,
      :worktree_path,
      :bare_path
    ) do
      def initialize(name:, agent_type:, worktree_path:, bare_path:, template: nil, kits: [], cpus: nil, memory: nil)
        super
      end
    end

    # Result of a single `doctor` environment check. `severity` is what a
    # failure of this check means: `:error` (blocks sandbox creation in
    # preflight) or `:warning` (reported only). Passing checks keep their
    # severity, so JSON consumers filter on `passed`, not severity.
    Check = Data.define(
      :name,
      :severity,
      :passed,
      :message
    ) do
      def self.pass(name, message)
        new(
          name: name,
          severity: :error,
          passed: true,
          message: message
        )
      end

      def self.fail(name, message)
        new(
          name: name,
          severity: :error,
          passed: false,
          message: message
        )
      end

      def self.warning(name, passed, message)
        new(
          name: name,
          severity: :warning,
          passed: passed,
          message: message
        )
      end

      # The JSON shape (field order + lowercase severity).
      def to_json_hash
        {
          "name" => name,
          "severity" => severity.to_s,
          "passed" => passed,
          "message" => message
        }
      end
    end

    # --- Prerequisite checks ---

    # Raises with an install hint when the `sbx` CLI is missing.
    def self.require_sbx_cli!(output_mode)
      return if SbxCli.on_path?(output_mode, "sbx")

      raise Orn::Error, "sbx not found on PATH\n  Install: https://docs.docker.com/reference/cli/sbx/"
    end

    # Raises with an install hint when docker is missing.
    def self.require_docker!(output_mode)
      return if SbxCli.on_path?(output_mode, "docker")

      raise Orn::Error, "docker not found on PATH\n  Install: https://docs.docker.com/get-docker/"
    end

    # --- Lifecycle ---

    # The shared provisioning sequence behind `orn switch --sbx` and
    # `orn sbx new`: create the sandbox, run the configured setup, publish
    # the configured ports. `on_created` fires right after the create
    # succeeds (switch records it for rollback); the block runs between
    # setup and ports (switch opens its tmux window there). Returns
    # [name, host_ports].
    def self.provision(output_mode, project, branch, sbx_config, agent_type, on_created: nil)
      name = project.sandbox_name(branch)
      output_mode.status("Creating sandbox '#{name}'...")
      SbxCli.create(
        output_mode,
        provision_params(
          project,
          branch,
          sbx_config,
          agent_type,
          name
        )
      )
      on_created&.call(name)

      unless sbx_config.setup.empty?
        run_setup(
          output_mode,
          name,
          sbx_config.setup,
          sbx_config.env
        )
      end
      yield name if block_given?
      [
        name,
        publish_provision_ports(
          output_mode,
          project,
          sbx_config,
          name
        )
      ]
    end

    def self.provision_params(project, branch, sbx_config, agent_type, name)
      CreateParams.new(
        name: name,
        template: sbx_config.template,
        kits: sbx_config.all_kits,
        cpus: sbx_config.cpus,
        memory: sbx_config.memory,
        agent_type: agent_type,
        worktree_path: project.worktree_path(branch),
        bare_path: File.join(project.root, ".bare")
      )
    end
    private_class_method :provision_params

    def self.publish_provision_ports(output_mode, project, sbx_config, name)
      return [] if sbx_config.ports.empty?

      Ports.setup_ports(
        output_mode,
        name,
        sbx_config.ports,
        File.join(project.root, ".orn")
      )
    end
    private_class_method :publish_provision_ports

    # Runs the configured setup commands in order with progress output,
    # stopping at the first failure.
    def self.run_setup(output_mode, name, commands, env)
      total = commands.length
      commands.each_with_index do |command, index|
        if total == 1
          output_mode.status("Running setup in '#{name}': #{command}")
        else
          output_mode.status("Running setup [#{index + 1}/#{total}] in '#{name}': #{command}")
        end
        begin
          SbxCli.exec_setup(
            output_mode,
            name,
            command,
            env
          )
        rescue Orn::Error
          raise Orn::Error, "Setup step #{index + 1} failed: #{command}"
        end
      end
      nil
    end

    # --- Build ---

    # Builds a Docker image and loads it as an sbx template: `docker build`,
    # `docker save` to a temp tar, then `sbx template load`. Build args are
    # resolved from the host environment and fail if unset.
    def self.build(output_mode, dockerfile, tag, build_args, context)
      build_arg_values = build_args.to_h do |arg|
        value = ENV.fetch(arg, nil)
        raise Orn::Error, "Build arg #{arg} not set in environment" if value.nil?

        [arg, value]
      end
      SbxCli.docker_build(
        output_mode,
        dockerfile,
        tag,
        build_arg_values,
        context
      )

      tar_path = File.join(Dir.tmpdir, "orn-#{safe_tar_name(tag)}.tar")
      save_and_load_template(
        output_mode,
        tag,
        tar_path
      )
      nil
    end

    # --- Internal helpers ---

    def self.safe_tar_name(tag)
      tag.chars.map { |char| char.match?(/[a-zA-Z0-9]/) || char == "-" || char == "." ? char : "-" }.join
    end

    # `docker save` to the tar, then `sbx template load`; the tar is always
    # cleaned up, and a failed save deletes the partial file before raising.
    def self.save_and_load_template(output_mode, tag, tar_path)
      begin
        SbxCli.docker_save(
          output_mode,
          tag,
          tar_path
        )
      rescue Orn::Error
        FileUtils.rm_f(tar_path)
        raise
      end

      begin
        SbxCli.template_load(output_mode, tar_path)
      ensure
        FileUtils.rm_f(tar_path)
      end
    end

    private_class_method :safe_tar_name,
      :save_and_load_template
  end
end
