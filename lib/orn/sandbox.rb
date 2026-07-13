# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"
require "tmpdir"
require "open3"
require "rbconfig"

module Orn
  # Sandbox (dev container) operations, shelling out to the `sbx` CLI and
  # docker: lifecycle, template builds, port publishing, and environment
  # checks (`doctor`). The Docker-free foundations (port reservation, `.ports`
  # persistence, `sbx ls` parsing) sit alongside the shelling operations.
  module Sandbox
    # Total time verify_port waits for a published port to accept connections.
    PORT_VERIFY_TIMEOUT = 30
    # Starting delay for verify_port's exponential backoff (seconds).
    PORT_VERIFY_INITIAL_BACKOFF = 0.25

    # A host-to-container port mapping, displayed as `host:container`.
    PortMapping = Data.define(:host, :container) do
      def to_s
        "#{host}:#{container}"
      end

      # String-keyed hash for `--json` output.
      def to_json_hash
        { "host" => host, "container" => container }
      end
    end

    # A sandbox name and status as reported by `sbx ls`.
    SandboxEntry = Data.define(:name, :status)

    # Inputs for the `sbx create` invocation. `worktree_path` and `bare_path`
    # are positional args after `agent_type`, in that order. `kits` defaults to
    # empty; `template`/`cpus`/`memory` are optional.
    CreateParams = Data.define(:name, :template, :kits, :cpus, :memory, :agent_type, :worktree_path, :bare_path) do
      def initialize(name:, agent_type:, worktree_path:, bare_path:, template: nil, kits: [], cpus: nil, memory: nil)
        super
      end
    end

    # Result of a single `doctor` environment check. `kind` is `:error`
    # (blocks sandbox creation in preflight) or `:warning` (reported only).
    Check = Data.define(:name, :kind, :passed, :message) do
      def self.pass(name, message)
        new(name: name, kind: :error, passed: true, message: message)
      end

      def self.fail(name, message)
        new(name: name, kind: :error, passed: false, message: message)
      end

      def self.warning(name, passed, message)
        new(name: name, kind: :warning, passed: passed, message: message)
      end

      # The JSON shape (field order + lowercase kind).
      def to_json_hash
        { "name" => name, "kind" => kind.to_s, "passed" => passed, "message" => message }
      end
    end

    # --- Prerequisite checks ---

    # True when the `sbx` CLI is on PATH.
    def self.available?(output_mode)
      on_path?(output_mode, "sbx")
    end

    # Raises with an install hint when the `sbx` CLI is missing.
    def self.require_sbx_cli!(output_mode)
      return if available?(output_mode)

      raise Orn::Error, "sbx not found on PATH\n  Install: https://docs.docker.com/reference/cli/sbx/"
    end

    # Raises with an install hint when docker is missing.
    def self.require_docker!(output_mode)
      return if on_path?(output_mode, "docker")

      raise Orn::Error, "docker not found on PATH\n  Install: https://docs.docker.com/get-docker/"
    end

    # --- Lifecycle ---

    # Creates a sandbox container via `sbx create`.
    def self.create(output_mode, params)
      sbx_exec(output_mode, *build_create_command(params))
    end

    def self.build_create_command(params)
      [
        "create", "--name", params.name,
        *optional_create_flags(params),
        *params.kits.flat_map { |kit| ["--kit", kit] },
        params.agent_type, params.worktree_path.to_s, params.bare_path.to_s
      ]
    end

    def self.optional_create_flags(params)
      flags = []
      flags.push("-t", params.template) unless params.template.nil?
      flags.push("--cpus", params.cpus.to_s) unless params.cpus.nil?
      flags.push("-m", params.memory) unless params.memory.nil?
      flags
    end

    # Runs a single setup command inside the sandbox via `sbx exec`, blocking
    # until it exits.
    def self.exec_setup(output_mode, name, setup_cmd, env)
      sbx_exec(output_mode, *build_exec_command(name, setup_cmd, env))
    end

    def self.build_exec_command(name, setup_cmd, env)
      build_exec_command_with(["exec", name], setup_cmd, env)
    end

    # Runs a command inside the sandbox detached (`sbx exec -d`); used for
    # long-running services that should outlive the call.
    def self.exec_detached(output_mode, name, detached_cmd, env)
      sbx_exec(output_mode, *build_exec_detached_command(name, detached_cmd, env))
    end

    def self.build_exec_detached_command(name, detached_cmd, env)
      build_exec_command_with(["exec", "-d", name], detached_cmd, env)
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
          exec_setup(output_mode, name, command, env)
        rescue Orn::Error
          raise Orn::Error, "Setup step #{index + 1} failed: #{command}"
        end
      end
      nil
    end

    # Removes a sandbox via `sbx rm --force`. The flag is required: without it
    # `sbx rm` prompts and fails when stdin is not a terminal.
    def self.remove(output_mode, name)
      sbx_exec(output_mode, "rm", "--force", name)
    end

    # Lists sandboxes via `sbx ls --json`. A non-zero exit is treated as an
    # empty list, not an error.
    def self.list(output_mode)
      result = run_sbx_ls(output_mode)
      return [] unless result.success?

      parse_list_output(result.stdout)
    end

    # Parses `sbx ls --json` output, accepting either a bare array or a
    # `{"sandboxes": [...]}` wrapper object.
    def self.parse_list_output(json)
      value = JSON.parse(json)
      case value
      when Array then extract_entries(value)
      when Hash then extract_entries(value["sandboxes"].is_a?(Array) ? value["sandboxes"] : [])
      else []
      end
    rescue JSON::ParserError
      raise Orn::Error, "Failed to parse sbx ls output"
    end

    # Skips entries without a name; a missing status defaults to "unknown".
    def self.extract_entries(items)
      items.filter_map do |item|
        next unless item.is_a?(Hash) && item["name"].is_a?(String)

        status = item["status"].is_a?(String) ? item["status"] : "unknown"
        SandboxEntry.new(name: item["name"], status: status)
      end
    end

    # True when `sbx inspect` succeeds for the name.
    def self.exists?(output_mode, name)
      Orn::Cmd.new(output_mode: output_mode).output("sbx", "inspect", name).success?
    rescue Orn::Error
      false
    end

    # Best-effort `sbx rm --force`; returns false on failure instead of raising.
    def self.try_remove(output_mode, name)
      Orn::Cmd.new(output_mode: output_mode).output("sbx", "rm", "--force", name).success?
    rescue Orn::Error
      false
    end

    # --- Build ---

    # Builds a Docker image and loads it as an sbx template: `docker build`,
    # `docker save` to a temp tar, then `sbx template load`. Build args are
    # resolved from the host environment and fail if unset.
    def self.build(output_mode, dockerfile, tag, build_args, context)
      docker_args = ["build", "-f", dockerfile, "-t", tag]
      build_args.each do |arg|
        value = ENV.fetch(arg, nil)
        raise Orn::Error, "Build arg #{arg} not set in environment" if value.nil?

        docker_args.push("--build-arg", "#{arg}=#{value}")
      end
      docker_args.push(context)
      Orn::Cmd.new(output_mode: output_mode).exec("docker", *docker_args)

      tar_path = File.join(Dir.tmpdir, "orn-#{safe_tar_name(tag)}.tar")
      save_and_load_template(output_mode, tag, tar_path)
      nil
    end

    # Checks `sbx template ls` for a matching repo, and tag when the template
    # is given as `repo:tag`. A failed listing reports the template as absent.
    def self.template_exists?(output_mode, template)
      result = run_template_ls(output_mode)
      return false unless result.success?

      repo, tag = template.split(":", 2)
      result.stdout.each_line.any? do |line|
        cols = line.split
        matches_repo = cols[0] == repo
        matches_tag = tag.nil? || cols[1] == tag
        matches_repo && matches_tag
      end
    end

    # --- Port management ---

    # The first bindable host port in `[start, end]`. The port is probed, not
    # held, so another process can still race for it.
    def self.reserve_port(host_range)
      start, finish = host_range
      (start..finish).each do |port|
        server = probe_bind(port)
        next if server.nil?

        server.close
        return port
      end
      raise Orn::Error, "No free port in range #{start}-#{finish}"
    end

    # Publishes a host-to-container port mapping via `sbx ports --publish`.
    def self.publish_port(output_mode, name, host_port, container_port)
      mapping = "#{host_port}:#{container_port}"
      sbx_exec(output_mode, "ports", name, "--publish", mapping)
    end

    # Polls the host port with exponential backoff until it accepts a TCP
    # connection or `timeout` seconds elapse.
    def self.verify_port(host_port, timeout, initial_backoff)
      start = monotonic
      backoff = initial_backoff
      loop do
        return if port_open?(host_port)

        elapsed = monotonic - start
        raise Orn::Error, "Port #{host_port} not reachable after #{timeout.to_i}s" if elapsed >= timeout

        remaining = timeout - elapsed
        sleep([backoff, remaining].min)
        backoff *= 2
      end
    end

    # Writes the mappings as JSON to `<orn_dir>/sandbox/<name>.ports` so they
    # can be republished after a container restart.
    def self.persist_ports(orn_dir, name, mappings)
      sandbox_dir = File.join(orn_dir, "sandbox")
      FileUtils.mkdir_p(sandbox_dir)
      File.write(File.join(sandbox_dir, "#{name}.ports"), JSON.generate(mappings.map(&:to_h)))
      nil
    rescue SystemCallError => e
      raise Orn::Error, "Failed to write sandbox ports for #{name}: #{e.message}"
    end

    # Deletes the persisted ports file plus the legacy single-port `.port` file;
    # missing files are ignored.
    def self.remove_ports_file(orn_dir, name)
      FileUtils.rm_f(File.join(orn_dir, "sandbox", "#{name}.ports"))
      FileUtils.rm_f(File.join(orn_dir, "sandbox", "#{name}.port"))
      nil
    end

    # Reads the mappings persisted by persist_ports.
    def self.read_ports(orn_dir, name)
      path = File.join(orn_dir, "sandbox", "#{name}.ports")
      parsed = JSON.parse(File.read(path))
      parsed.map { |entry| PortMapping.new(host: entry["host"], container: entry["container"]) }
    rescue Errno::ENOENT
      raise Orn::Error, "Failed to read #{path}"
    rescue JSON::ParserError
      raise Orn::Error, "Invalid port data in #{path}"
    end

    # --- Composite helpers ---

    # Runs the `doctor` checks before sandbox creation: raises on the first
    # error-level failure, reports warning-level failures, and continues.
    def self.preflight(output_mode, config, project_root)
      checks = doctor(output_mode, config, project_root)
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

    # Reserves, publishes, and verifies each configured port, then persists the
    # mappings. Entries missing a container port or host range are skipped.
    def self.setup_ports(output_mode, name, ports, orn_dir)
      mappings = []
      ports.each do |entry|
        next if entry.container.nil? || entry.host_range.nil?

        host = reserve_port(entry.host_range)
        output_mode.status("Publishing port #{host}:#{entry.container}...")
        publish_port(output_mode, name, host, entry.container)
        verify_port(host, PORT_VERIFY_TIMEOUT, PORT_VERIFY_INITIAL_BACKOFF)
        mappings.push(PortMapping.new(host: host, container: entry.container))
      end
      persist_ports(orn_dir, name, mappings) unless mappings.empty?
      mappings
    end

    # Re-publishes previously persisted port mappings, e.g. after a container
    # restart. A missing or unreadable ports file is a no-op.
    def self.republish_ports(output_mode, name, orn_dir)
      mappings = read_persisted_ports(orn_dir, name)
      return [] if mappings.nil?

      mappings.each do |mapping|
        output_mode.status("Publishing port #{mapping}...")
        publish_port(output_mode, name, mapping.host, mapping.container)
        verify_port(mapping.host, PORT_VERIFY_TIMEOUT, PORT_VERIFY_INITIAL_BACKOFF)
      end
      mappings
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

    # Template, kits, and build inputs derived from the [sbx] config.
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
      config_path = File.join(project_root, ".bare", "config")
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
        Check.warning("ssh-auth", true, "SSH_AUTH_SOCK is set")
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
      missing = "No github secret configured; gh CLI will not work in sandbox.\n    Run: sbx secret set -g github"
      result = sbx_secret_ls(output_mode)
      return Check.warning("github-secret", false, missing) if result.nil? || !result.success?

      found = result.stdout.each_line.any? { |line| line.split.include?("github") }
      return Check.warning("github-secret", true, "github secret configured") if found

      Check.warning("github-secret", false, missing)
    end

    def self.tool_check(output_mode, tool)
      if on_path?(output_mode, tool)
        Check.pass(tool, "#{tool} found on PATH")
      else
        Check.fail(tool, "#{tool} not found on PATH")
      end
    end

    def self.colima_check(output_mode)
      result = colima_status(output_mode)
      return Check.fail("colima", "Colima not running") if result.nil? || !result.success?

      arch = colima_arch(result.stdout)
      arch ? Check.pass("colima", "Colima running (#{arch})") : Check.pass("colima", "Colima running")
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
        Orn::Cmd.new(output_mode: output_mode).exec("docker", "save", "-o", tar_path, tag)
      rescue Orn::Error
        FileUtils.rm_f(tar_path)
        raise
      end

      begin
        Orn::Cmd.new(output_mode: output_mode).exec("sbx", "template", "load", tar_path)
      ensure
        FileUtils.rm_f(tar_path)
      end
    end

    # Reads persisted ports, returning nil (rather than raising) when the file
    # is missing or unreadable, so republish can no-op.
    def self.read_persisted_ports(orn_dir, name)
      read_ports(orn_dir, name)
    rescue Orn::Error
      nil
    end

    def self.template_present?(output_mode, template)
      template_exists?(output_mode, template)
    rescue Orn::Error
      false
    end

    # True when `key` is set in the given git config file; system and global
    # config are masked out so only that file is consulted.
    def self.git_config_set?(config_path, key)
      env = { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null" }
      _stdout, _stderr, status = Open3.capture3(
        env, "git", "config", "--file", config_path.to_s, key, chdir: Dir.tmpdir
      )
      status.success?
    rescue SystemCallError
      false
    end

    def self.colima_arch(stdout)
      parsed = JSON.parse(stdout)
      parsed.is_a?(Hash) && parsed["arch"].is_a?(String) ? parsed["arch"] : nil
    rescue JSON::ParserError
      nil
    end

    def self.on_path?(output_mode, tool)
      Orn::Cmd.new(output_mode: output_mode).output("which", tool).success?
    rescue Orn::Error
      false
    end

    # Shared builder for foreground and detached exec: produces
    # `sbx <exec_args> -- [env K=V ...] sh -c <shell_cmd>`. Env vars are
    # injected with an `env(1)` prefix (sorted by key) since `sbx exec` has no flag for them.
    def self.build_exec_command_with(exec_args, shell_cmd, env)
      args = [*exec_args, "--"]
      unless env.empty?
        args.push("env")
        env.sort.each { |key, value| args.push("#{key}=#{value}") }
      end
      args.push("sh", "-c", shell_cmd)
      args
    end

    def self.sbx_exec(output_mode, *args)
      Orn::Cmd.new(output_mode: output_mode).exec("sbx", *args)
    end

    def self.run_sbx_ls(output_mode)
      Orn::Cmd.new(output_mode: output_mode).output("sbx", "ls", "--json")
    rescue Orn::Error
      raise Orn::Error, "Failed to run sbx ls"
    end

    def self.run_template_ls(output_mode)
      Orn::Cmd.new(output_mode: output_mode).output("sbx", "template", "ls")
    rescue Orn::Error
      raise Orn::Error, "Failed to run sbx template ls"
    end

    def self.sbx_secret_ls(output_mode)
      Orn::Cmd.new(output_mode: output_mode).output("sbx", "secret", "ls")
    rescue Orn::Error
      nil
    end

    def self.colima_status(output_mode)
      Orn::Cmd.new(output_mode: output_mode).output("colima", "status", "--json")
    rescue Orn::Error
      nil
    end

    def self.probe_bind(port)
      TCPServer.new("127.0.0.1", port)
    rescue SystemCallError
      nil
    end

    def self.port_open?(port)
      TCPSocket.new("127.0.0.1", port).close
      true
    rescue SystemCallError
      false
    end

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    private_class_method :optional_create_flags, :tool_and_platform_checks, :config_checks,
      :macos?, :safe_tar_name, :save_and_load_template, :read_persisted_ports,
      :template_present?, :git_config_set?, :colima_arch, :on_path?, :build_exec_command_with,
      :sbx_exec, :run_sbx_ls, :run_template_ls, :sbx_secret_ls, :colima_status,
      :probe_bind, :port_open?, :monotonic
  end
end
