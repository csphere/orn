# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "open3"
require "rbconfig"

module Orn
  # Sandbox (dev container) operations: lifecycle, template builds, port
  # publishing, and environment checks (`doctor`). Every sbx/docker/colima
  # invocation goes through the SbxCli adapter, port handling lives in Ports,
  # and this module holds the policy around those calls (ordering, cleanup,
  # error wrapping) plus the public interface commands call.
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

    # True when the `sbx` CLI is on PATH.
    def self.available?(output_mode)
      SbxCli.on_path?(output_mode, "sbx")
    end

    # Raises with an install hint when the `sbx` CLI is missing.
    def self.require_sbx_cli!(output_mode)
      return if available?(output_mode)

      raise Orn::Error, "sbx not found on PATH\n  Install: https://docs.docker.com/reference/cli/sbx/"
    end

    # Raises with an install hint when docker is missing.
    def self.require_docker!(output_mode)
      return if SbxCli.on_path?(output_mode, "docker")

      raise Orn::Error, "docker not found on PATH\n  Install: https://docs.docker.com/get-docker/"
    end

    # --- Lifecycle ---

    def self.create(output_mode, params)
      SbxCli.create(output_mode, params)
    end

    # Runs a command inside the sandbox detached; used for long-running
    # services that should outlive the call.
    def self.exec_detached(output_mode, name, detached_cmd, env)
      SbxCli.exec_detached(
        output_mode,
        name,
        detached_cmd,
        env
      )
    end

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

    def self.remove(output_mode, name)
      SbxCli.remove(output_mode, name)
    end

    def self.list(output_mode)
      SbxCli.list(output_mode)
    end

    def self.exists?(output_mode, name)
      SbxCli.exists?(output_mode, name)
    end

    def self.try_remove(output_mode, name)
      SbxCli.try_remove(output_mode, name)
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

    # --- Port management ---

    def self.remove_ports_file(orn_dir, name)
      Ports.remove_ports_file(orn_dir, name)
    end

    def self.read_ports(orn_dir, name)
      Ports.read_ports(orn_dir, name)
    end

    def self.setup_ports(output_mode, name, ports, orn_dir)
      Ports.setup_ports(
        output_mode,
        name,
        ports,
        orn_dir
      )
    end

    def self.republish_ports(output_mode, name, orn_dir)
      Ports.republish_ports(
        output_mode,
        name,
        orn_dir
      )
    end

    # --- Composite helpers ---

    # Runs the `doctor` checks before sandbox creation: raises on the first
    # error-level failure, reports warning-level failures, and continues.
    def self.preflight(output_mode, config, project_root)
      checks = doctor(
        output_mode,
        config,
        project_root
      )
      failed = checks.find { |check| !check.passed && check.kind == :error }
      if failed
        raise Orn::Error,
          "Preflight check failed: #{failed.message}\n  " \
            "Run `orn sbx doctor` for a full environment check."
      end

      checks.each do |check|
        output_mode.status("Warning: #{check.message}") if !check.passed && check.kind == :warning
      end
      nil
    end

    # --- Doctor ---

    # Runs the full set of sandbox environment checks: required tools, colima
    # (macOS only), git identity, template, kits, build inputs, ssh agent, and
    # the github secret.
    def self.doctor(output_mode, config, project_root)
      checks = tool_and_platform_checks(output_mode)
      checks << git_identity_check(output_mode, project_root)
      checks.concat(config_checks(output_mode, config))
      checks << ssh_auth_check
      checks << github_secret_check(output_mode)
      checks
    end

    # Required tools plus colima on macOS.
    def self.tool_and_platform_checks(output_mode)
      checks = [tool_check(output_mode, "sbx"), tool_check(output_mode, "docker")]
      checks << colima_check(output_mode) if macos?
      checks
    end

    # Template, kits, and build inputs derived from the sbx config.
    def self.config_checks(output_mode, config)
      checks = []
      checks << template_check(output_mode, config.template) if config.template
      config.all_kits.each { |kit| checks << path_check("kit:#{kit}", kit) }
      if config.build
        checks << path_check("dockerfile", config.build.dockerfile) if config.build.dockerfile
        config.build.build_args.each { |arg| checks << env_check(arg) }
      end
      checks
    end

    # Checks that `user.name` and `user.email` are set in the repo's own
    # `.bare/config`; host global and system git config are ignored.
    def self.git_identity_check(_output_mode, project_root)
      config_path = File.join(
        project_root,
        ".bare",
        "config"
      )
      has_name = git_config_set?(config_path, "user.name")
      has_email = git_config_set?(config_path, "user.email")

      if has_name && has_email
        Check.pass("git-identity", "Git user.name and user.email configured")
      else
        Check.fail(
          "git-identity",
          "Git identity not configured in repo config.\n    " \
            "Run: git config --local user.name \"Your Name\"\n         " \
            "git config --local user.email \"you@example.com\""
        )
      end
    end

    def self.ssh_auth_check
      if ENV.key?("SSH_AUTH_SOCK")
        Check.warning(
          "ssh-auth",
          true,
          "SSH_AUTH_SOCK is set"
        )
      else
        Check.warning(
          "ssh-auth",
          false,
          "SSH_AUTH_SOCK not set; agent will not be able to git push.\n    " \
            "Commits will be available in the host worktree."
        )
      end
    end

    # Warns unless a `github` secret is registered per `sbx secret ls`; without
    # it the `gh` CLI cannot authenticate inside the sandbox.
    def self.github_secret_check(output_mode)
      if SbxCli.secret_listed?(output_mode, "github")
        Check.warning(
          "github-secret",
          true,
          "github secret configured"
        )
      else
        Check.warning(
          "github-secret",
          false,
          "No github secret configured; gh CLI will not work in sandbox.\n    Run: sbx secret set -g github"
        )
      end
    end

    def self.tool_check(output_mode, tool)
      if SbxCli.on_path?(output_mode, tool)
        Check.pass(tool, "#{tool} found on PATH")
      else
        Check.fail(tool, "#{tool} not found on PATH")
      end
    end

    def self.colima_check(output_mode)
      status = SbxCli.colima_status(output_mode)
      return Check.fail("colima", "Colima not running") unless status.running

      status.arch ? Check.pass("colima", "Colima running (#{status.arch})") : Check.pass("colima", "Colima running")
    end

    def self.template_check(output_mode, template)
      if template_present?(output_mode, template)
        Check.pass("template", "Template '#{template}' found")
      else
        Check.fail("template", "Template '#{template}' not found")
      end
    end

    def self.path_check(label, path)
      if File.exist?(path)
        Check.pass(label, "#{label} '#{path}' exists")
      else
        Check.fail(label, "#{label} '#{path}' not found")
      end
    end

    # Testable core of env_check with an injectable variable lookup block.
    def self.env_check_with(var, &lookup)
      if lookup.call(var)
        Check.pass("env:#{var}", "#{var} is set")
      else
        Check.fail("env:#{var}", "#{var} not set in environment")
      end
    end

    def self.env_check(var)
      env_check_with(var) { |name| ENV.fetch(name, nil) }
    end

    # --- Internal helpers ---

    def self.macos?
      RbConfig::CONFIG["host_os"].include?("darwin")
    end

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

    def self.template_present?(output_mode, template)
      SbxCli.template_exists?(output_mode, template)
    rescue Orn::Error
      false
    end

    # True when `key` is set in the given git config file; system and global
    # config are masked out so only that file is consulted.
    def self.git_config_set?(config_path, key)
      env = {
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null"
      }
      _stdout, _stderr, status = Open3.capture3(
        env,
        "git",
        "config",
        "--file",
        config_path.to_s,
        key,
        chdir: Dir.tmpdir
      )
      status.success?
    rescue SystemCallError
      false
    end

    private_class_method :tool_and_platform_checks,
      :config_checks,
      :macos?,
      :safe_tar_name,
      :save_and_load_template,
      :template_present?,
      :git_config_set?
  end
end
