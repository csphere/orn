# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"

module Orn
  module Sandbox
    # Environment checks behind `orn sbx doctor` and the preflight gate run
    # before sandbox creation. `run` walks CHECK_STEPS in order; each step
    # turns the Context into zero or more Check values, so adding a check
    # means appending a step and defining its method.
    module Doctor
      # Everything a check step can look at.
      Context = Data.define(
        :output_mode,
        :config,
        :project_root
      )

      # Every check in report order.
      CHECK_STEPS = %i[
        sbx_tool_checks
        docker_tool_checks
        colima_checks
        git_identity_checks
        template_checks
        kit_checks
        dockerfile_checks
        build_arg_checks
        ssh_auth_checks
        github_secret_checks
      ].freeze

      # Runs the full set of sandbox environment checks: required tools,
      # colima (macOS only), git identity, template, kits, build inputs, ssh
      # agent, and the github secret.
      def self.run(output_mode, config, project_root)
        context = Context.new(
          output_mode: output_mode,
          config: config,
          project_root: project_root
        )
        CHECK_STEPS.flat_map { |step| send(step, context) }
      end

      # Runs the checks before sandbox creation: raises on the first
      # error-level failure, reports warning-level failures, and continues.
      def self.preflight(output_mode, config, project_root)
        checks = run(
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

      # --- Check steps ---

      def self.sbx_tool_checks(context)
        [tool_check(context.output_mode, "sbx")]
      end

      def self.docker_tool_checks(context)
        [tool_check(context.output_mode, "docker")]
      end

      def self.colima_checks(context)
        macos? ? [colima_check(context.output_mode)] : []
      end

      def self.git_identity_checks(context)
        [git_identity_check(context.project_root)]
      end

      def self.template_checks(context)
        template = context.config.template
        template ? [template_check(context.output_mode, template)] : []
      end

      def self.kit_checks(context)
        context.config.all_kits.map { |kit| path_check("kit:#{kit}", kit) }
      end

      def self.dockerfile_checks(context)
        dockerfile = context.config.build&.dockerfile
        dockerfile ? [path_check("dockerfile", dockerfile)] : []
      end

      def self.build_arg_checks(context)
        build = context.config.build
        build ? build.build_args.map { |arg| env_check(arg) } : []
      end

      def self.ssh_auth_checks(_context)
        [ssh_auth_check]
      end

      def self.github_secret_checks(context)
        [github_secret_check(context.output_mode)]
      end

      # --- Individual checks ---

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

      # Checks that `user.name` and `user.email` are set in the repo's own
      # `.bare/config`; host global and system git config are ignored.
      def self.git_identity_check(project_root)
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

      # Warns unless a `github` secret is registered per `sbx secret ls`;
      # without it the `gh` CLI cannot authenticate inside the sandbox.
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

      # --- Internal helpers ---

      def self.macos?
        RbConfig::CONFIG["host_os"].include?("darwin")
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

      private_class_method :sbx_tool_checks,
        :docker_tool_checks,
        :colima_checks,
        :git_identity_checks,
        :template_checks,
        :kit_checks,
        :dockerfile_checks,
        :build_arg_checks,
        :ssh_auth_checks,
        :github_secret_checks,
        :macos?,
        :template_present?,
        :git_config_set?
    end
  end
end
