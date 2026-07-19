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

    # Result of a single `doctor` environment check. `kind` is `:error`
    # (blocks sandbox creation in preflight) or `:warning` (reported only).
    Check = Data.define(
      :name,
      :kind,
      :passed,
      :message
    ) do
      def self.pass(name, message)
        new(
          name: name,
          kind: :error,
          passed: true,
          message: message
        )
      end

      def self.fail(name, message)
        new(
          name: name,
          kind: :error,
          passed: false,
          message: message
        )
      end

      def self.warning(name, passed, message)
        new(
          name: name,
          kind: :warning,
          passed: passed,
          message: message
        )
      end

      # The JSON shape (field order + lowercase kind).
      def to_json_hash
        {
          "name" => name,
          "kind" => kind.to_s,
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
