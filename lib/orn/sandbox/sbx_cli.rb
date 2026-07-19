# frozen_string_literal: true

require "json"

module Orn
  module Sandbox
    # Adapter for the external CLIs that sandbox operations shell out to:
    # sbx, docker, and colima. Owns argv construction and output parsing for
    # those commands; the rest of the sandbox code calls these methods
    # instead of running Orn::Cmd itself.
    module SbxCli
      # `colima status --json` distilled: whether colima is up, plus its
      # reported arch when the status output includes one.
      ColimaStatus = Data.define(:running, :arch)

      # --- Lifecycle ---

      # Creates a sandbox via `sbx create`.
      def self.create(output_mode, params)
        sbx_exec(output_mode, *build_create_command(params))
      end

      def self.build_create_command(params)
        [
          "create",
          "--name",
          params.name,
          *optional_create_flags(params),
          *params.kits.flat_map { |kit| ["--kit", kit] },
          params.agent_type,
          params.worktree_path.to_s,
          params.bare_path.to_s
        ]
      end

      def self.optional_create_flags(params)
        flags = []
        flags.push("-t", params.template) unless params.template.nil?
        flags.push("--cpus", params.cpus.to_s) unless params.cpus.nil?
        flags.push("-m", params.memory) unless params.memory.nil?
        flags
      end

      # Runs a single command inside the sandbox via `sbx exec`, blocking
      # until it exits.
      def self.exec_setup(output_mode, name, setup_cmd, env)
        sbx_exec(
          output_mode,
          *build_exec_command(
            name,
            setup_cmd,
            env
          )
        )
      end

      def self.build_exec_command(name, setup_cmd, env)
        build_exec_command_with(
          ["exec", name],
          setup_cmd,
          env
        )
      end

      # Runs a command inside the sandbox detached (`sbx exec -d`); used for
      # long-running services that should outlive the call.
      def self.exec_detached(output_mode, name, detached_cmd, env)
        sbx_exec(
          output_mode,
          *build_exec_detached_command(
            name,
            detached_cmd,
            env
          )
        )
      end

      def self.build_exec_detached_command(name, detached_cmd, env)
        build_exec_command_with(
          ["exec", "-d", name],
          detached_cmd,
          env
        )
      end

      # Removes a sandbox via `sbx rm --force`. The flag is required: without
      # it `sbx rm` prompts and fails when stdin is not a terminal.
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
          SandboxEntry.new(
            name: item["name"],
            status: status
          )
        end
      end

      # True when `sbx inspect` succeeds for the name.
      def self.exists?(output_mode, name)
        Orn::Cmd.new(output_mode: output_mode).output("sbx", "inspect", name).success?
      rescue Orn::Error
        false
      end

      # Best-effort `sbx rm --force`; returns false on failure instead of
      # raising.
      def self.try_remove(output_mode, name)
        Orn::Cmd.new(output_mode: output_mode).output("sbx", "rm", "--force", name).success?
      rescue Orn::Error
        false
      end

      # Publishes a host-to-container port mapping via `sbx ports --publish`.
      def self.publish_port(output_mode, name, host_port, container_port)
        mapping = "#{host_port}:#{container_port}"
        sbx_exec(output_mode, "ports", name, "--publish", mapping)
      end

      # --- Templates ---

      # Checks `sbx template ls` for a matching repo, and tag when the
      # template is given as `repo:tag`. A failed listing reports the template
      # as absent.
      def self.template_exists?(output_mode, template)
        result = run_template_ls(output_mode)
        return false unless result.success?

        template_listed?(result.stdout, template)
      end

      # Whether an `sbx template ls` listing contains the template. The
      # listing prints repositories registry-qualified
      # (`docker.io/library/<name>` for a bare name), so a configured repo
      # also matches any `<registry>/` prefix.
      def self.template_listed?(listing, template)
        repo, tag = template.split(":", 2)
        listing.each_line.any? do |line|
          cols = line.split
          listed_repo = cols[0]
          next false if listed_repo.nil?

          matches_repo = listed_repo == repo || listed_repo.end_with?("/#{repo}")
          matches_tag = tag.nil? || cols[1] == tag
          matches_repo && matches_tag
        end
      end

      # Loads a saved image tar as an sbx template.
      def self.template_load(output_mode, tar_path)
        Orn::Cmd.new(output_mode: output_mode).exec(
          "sbx",
          "template",
          "load",
          tar_path
        )
      end

      # --- Docker ---

      # Builds a Docker image from the Dockerfile. `build_arg_values` maps
      # `--build-arg` names to already-resolved values.
      def self.docker_build(output_mode, dockerfile, tag, build_arg_values, context)
        docker_args = ["build", "-f", dockerfile, "-t", tag]
        build_arg_values.each do |arg, value|
          docker_args.push("--build-arg", "#{arg}=#{value}")
        end
        docker_args.push(context)
        Orn::Cmd.new(output_mode: output_mode).exec("docker", *docker_args)
      end

      # `docker save` of the tagged image to a tar file.
      def self.docker_save(output_mode, tag, tar_path)
        Orn::Cmd.new(output_mode: output_mode).exec(
          "docker",
          "save",
          "-o",
          tar_path,
          tag
        )
      end

      # --- Environment probes ---

      # True when `sbx secret ls` lists the secret; a failed listing reports
      # it as absent.
      def self.secret_listed?(output_mode, secret_name)
        result = run_secret_ls(output_mode)
        return false if result.nil? || !result.success?

        result.stdout.each_line.any? { |line| line.split.include?(secret_name) }
      end

      def self.colima_status(output_mode)
        result = run_colima_status(output_mode)
        if result.nil? || !result.success?
          return ColimaStatus.new(
            running: false,
            arch: nil
          )
        end

        ColimaStatus.new(
          running: true,
          arch: colima_arch(result.stdout)
        )
      end

      def self.on_path?(output_mode, tool)
        Orn::Cmd.new(output_mode: output_mode).output("which", tool).success?
      rescue Orn::Error
        false
      end

      # --- Internal helpers ---

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

      def self.run_secret_ls(output_mode)
        Orn::Cmd.new(output_mode: output_mode).output("sbx", "secret", "ls")
      rescue Orn::Error
        nil
      end

      def self.run_colima_status(output_mode)
        Orn::Cmd.new(output_mode: output_mode).output("colima", "status", "--json")
      rescue Orn::Error
        nil
      end

      def self.colima_arch(stdout)
        parsed = JSON.parse(stdout)
        parsed.is_a?(Hash) && parsed["arch"].is_a?(String) ? parsed["arch"] : nil
      rescue JSON::ParserError
        nil
      end

      # Shared builder for foreground and detached exec: produces
      # `sbx <exec_args> -- [env K=V ...] sh -c <shell_cmd>`. Env vars are
      # injected with an `env(1)` prefix (sorted by key) since `sbx exec` has
      # no flag for them.
      def self.build_exec_command_with(exec_args, shell_cmd, env)
        args = [*exec_args, "--"]
        unless env.empty?
          args.push("env")
          env.sort.each { |key, value| args.push("#{key}=#{value}") }
        end
        args.push(
          "sh",
          "-c",
          shell_cmd
        )
        args
      end

      private_class_method :optional_create_flags,
        :extract_entries,
        :sbx_exec,
        :run_sbx_ls,
        :run_template_ls,
        :run_secret_ls,
        :run_colima_status,
        :colima_arch,
        :build_exec_command_with
    end
  end
end
